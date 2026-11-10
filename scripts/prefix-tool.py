#!/usr/bin/env python3
"""Prepare an unlogged official Wine prefix without following archive links."""
import argparse
import os
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
import tempfile
import time
import zlib

OFFICIAL_ENGINE = '/opt/deepin-wine10-stable'
FIXED_LINKS = {
    'dosdevices/c:': '../drive_c',
    'dosdevices/z:': '/',
    'dosdevices/com1': '/dev/ttyS0',
    'dosdevices/d::': '/dev/sr0',
}


def entries(archive):
    listing = subprocess.check_output(['7z', 'l', '-slt', str(archive)], text=True)
    if '----------\n' not in listing:
        raise ValueError('7-Zip did not return a member listing')
    result = []
    seen = set()
    for block in listing.split('----------\n', 1)[1].split('\n\n'):
        fields = dict(line.split(' = ', 1) for line in block.splitlines() if ' = ' in line)
        if 'Path' not in fields:
            continue
        name = fields['Path']
        path = PurePosixPath(name)
        if (not name or path.is_absolute() or '..' in path.parts or '\\' in name
                or any(ord(c) < 32 for c in name) or name != str(path)
                or name in seen):
            raise ValueError(f'Unsafe or duplicate archive member: {name!r}')
        seen.add(name)
        mode = fields.get('Attributes', '').split()[-1:]
        fields['link'] = bool(mode and mode[0].startswith('l'))
        if fields.get('Encrypted') != '-':
            raise ValueError(f'Encrypted or unsupported archive member: {name!r}')
        result.append(fields)
    if not result:
        raise ValueError('Empty official prefix archive')
    links = {e['Path'] for e in result if e['link']}
    for entry in result:
        if any(str(parent) in links for parent in PurePosixPath(entry['Path']).parents):
            raise ValueError(f'Archive member traverses a symbolic link: {entry["Path"]}')
    return result


def extract(archive, dest, engine):
    if dest.exists() or dest.is_symlink():
        raise ValueError(f'Refusing existing prefix: {dest}')
    members = entries(archive)
    links = [e for e in members if e['link']]
    with tempfile.TemporaryDirectory(prefix='wxwork-archive-') as work:
        work = Path(work)
        names = work / 'links.txt'
        names.write_text(''.join(e['Path'] + '\n' for e in links))
        data = subprocess.check_output(['7z', 'x', '-so', str(archive), '@' + str(names)]) if links else b''
        offset = 0
        targets = []
        for entry in links:
            size = int(entry['Size'])
            value = data[offset:offset + size]
            offset += size
            if len(value) != size or f'{zlib.crc32(value):08X}' != entry.get('CRC'):
                raise ValueError(f'Invalid link payload order or checksum: {entry["Path"]}')
            target = value.decode('utf-8')
            name = entry['Path']
            if name in FIXED_LINKS and target == FIXED_LINKS[name]:
                pass
            elif (target.startswith(OFFICIAL_ENGINE + '/lib/wine/')
                  or target.startswith(OFFICIAL_ENGINE + '/share/wine/')):
                relative = PurePosixPath(target).relative_to(OFFICIAL_ENGINE)
                if '..' in relative.parts or any(ord(c) < 32 for c in target):
                    raise ValueError(f'Unsafe engine link: {name}')
                target = str(engine / str(relative))
                if not Path(target).is_file():
                    raise ValueError(f'Engine link target missing: {target}')
            else:
                raise ValueError(f'Unsupported official link: {name} -> {target}')
            targets.append((name, target))
        if offset != len(data):
            raise ValueError('Unexpected trailing symbolic-link payload')
        dest.mkdir()
        command = ['7z', 'x', '-y', '-bd', str(archive), '-o' + str(dest)]
        if links:
            command.append('-x@' + str(names))
        subprocess.run(command, check=True)
        for name, target in targets:
            link = dest / name
            if link.exists() or link.is_symlink():
                raise ValueError(f'Link exclusion did not work: {name}')
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
    print(f'Official prefix extracted; safely rebuilt {len(links)} known links')


def path_forms(value):
    windows = 'Z:' + value.replace('/', '\\')
    return [(value, 'unix'), (windows.replace('\\', '\\\\'), 'registry')]


def relocate(prefix, old_engine, new_engine, old_user, new_user, old_prefix, new_prefix):
    userdir = prefix / 'drive_c/users' / old_user
    if old_user != new_user:
        newdir = userdir.with_name(new_user)
        if newdir.exists() or newdir.is_symlink():
            raise ValueError(f'Username target already exists: {newdir}')
        userdir.rename(newdir)
    count = 0
    for root, dirs, files in os.walk(prefix, followlinks=False):
        for name in dirs + files:
            link = Path(root) / name
            if not link.is_symlink():
                continue
            target = os.readlink(link)
            if target.startswith(old_engine + '/'):
                replacement = new_engine + target[len(old_engine):]
                link.unlink()
                link.symlink_to(replacement)
                count += 1
    replacements = [(old_engine, new_engine), (OFFICIAL_ENGINE, new_engine)]
    if old_prefix and new_prefix:
        replacements.append((old_prefix, new_prefix))
    for reg in prefix.glob('*.reg'):
        text = reg.read_text()
        for old, new in replacements:
            for (before, kind), (after, _) in zip(path_forms(old), path_forms(new)):
                text = text.replace(before, after)
        text = re.sub(r'(?<![\w@])' + re.escape(old_user) + r'(?![\w@])', lambda m: new_user, text)
        reg.write_text(text)
    print(f'Relocated {count} engine links and prefix registry paths')


def version(exe, expected):
    data = exe.read_bytes()
    offset = data.find(bytes.fromhex('bd04effe00000100'))
    if offset < 0 or offset + 16 > len(data):
        raise ValueError('No VS_FIXEDFILEINFO in installed EXE')
    ms, ls = struct.unpack_from('<II', data, offset + 8)
    actual = '.'.join(str(n) for n in (ms >> 16, ms & 65535, ls >> 16, ls & 65535))
    if actual != expected:
        raise ValueError(f'Installed program version {actual} does not match requested {expected}')
    print(f'Installed EXE version verified: {actual}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('extract')
    p.add_argument('archive', type=Path)
    p.add_argument('prefix', type=Path)
    p.add_argument('engine', type=Path)
    p = sub.add_parser('relocate')
    for name in ('prefix', 'old_engine', 'new_engine', 'old_user', 'new_user', 'old_prefix', 'new_prefix'):
        p.add_argument(name)
    p = sub.add_parser('version')
    p.add_argument('exe', type=Path)
    p.add_argument('expected')
    p.add_argument('--wait', type=int, default=0)
    args = parser.parse_args()
    if args.command == 'extract':
        extract(args.archive.resolve(), args.prefix.absolute(), args.engine.resolve())
    elif args.command == 'relocate':
        relocate(Path(args.prefix), args.old_engine, args.new_engine, args.old_user, args.new_user,
                 args.old_prefix, args.new_prefix)
    else:
        deadline = time.monotonic() + args.wait
        while True:
            try:
                version(args.exe, args.expected)
                break
            except (OSError, ValueError):
                if time.monotonic() >= deadline:
                    raise
                time.sleep(1)


if __name__ == '__main__':
    main()
