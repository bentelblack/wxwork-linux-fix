import io
import os
import pwd
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wxwork-runtime-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.app.mkdir()
        self.prefix = self.root / 'prefix'
        self.home = self.root / 'home'
        self.home.mkdir()
        self.trace = self.root / 'wine-calls'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        notify = self.bin / 'notify-send'
        notify.write_text('#!/bin/sh\nexit 0\n')
        notify.chmod(0o755)
        shutil.copy(REPO / 'scripts/run.sh', self.app / 'run.sh')
        for mode in ['wine', 'wine-update']:
            engine = self.app / mode
            (engine / 'bin').mkdir(parents=True)
            (engine / 'lib/wine/i386-windows').mkdir(parents=True)
            (engine / 'lib/wine/i386-windows/kernelbase.dll').write_text(mode)
            script = engine / 'bin/wine'
            script.write_text('#!/bin/bash\nset -eu\nprintf "%s|%s|%s|%s\\n" "$APPRUN_CMD" "$WINEPREDLL" "$*" "$(readlink "$WINEPREFIX/drive_c/windows/syswow64/kernelbase.dll")" >> "$TEST_TRACE"\nif [ "${TEST_FAIL:-}" = yes ]; then exit 8; fi\n')
            script.chmod(0o755)
        (self.app / 'dlls').mkdir()
        server = self.app / 'dlls/wineserver'
        server.write_text('#!/bin/sh\nexit 0\n')
        server.chmod(0o755)
        (self.app / 'pre_run.sh').write_text('CallPreRun() { printf "probe\\n" >> "$TEST_TRACE"; }\n')
        shutil.copy(REPO / 'packaging/user.reg.append', self.app / 'font.reg')
        (self.app / 'fonts').mkdir()
        (self.app / 'fonts/wqy-microhei.ttc').write_text('font')
        (self.app / 'prefix.schema').write_text('official-v1\n')
        (self.app / 'prefix.version').write_text('5.0.13.6005\n')
        self.template = self.root / 'template'
        (self.template / 'drive_c/users/@current_user@').mkdir(parents=True)
        (self.template / 'drive_c/Program Files (x86)/WXWork').mkdir(parents=True)
        (self.template / 'drive_c/Program Files (x86)/WXWork/WXWork.exe').write_text('program')
        (self.template / 'drive_c/windows/syswow64').mkdir(parents=True)
        (self.template / 'drive_c/windows/syswow64/kernelbase.dll').symlink_to(self.app / 'wine/lib/wine/i386-windows/kernelbase.dll')
        (self.template / 'system.reg').write_text('WINE REGISTRY Version 2\n')
        (self.template / 'user.reg').write_text('official-rule=native,builtin\nuser=@current_user@\n')
        (self.template / 'prefix.schema').write_text('official-v1\n')
        self.archive()

    def archive(self):
        with tarfile.open(self.app / 'prefix.tar.xz', 'w:xz') as tar:
            tar.add(self.template, arcname='.')

    def run_entry(self, *args, fail=False):
        env = os.environ.copy()
        env.pop('WINEPREFIX', None)
        env.update(PATH=str(self.bin) + os.pathsep + env['PATH'], HOME=str(self.home), WXWORK_PREFIX=str(self.prefix), TEST_TRACE=str(self.trace), TEST_FAIL='yes' if fail else 'no')
        return subprocess.run(['bash', str(self.app / 'run.sh'), *args], env=env, capture_output=True, text=True, timeout=20)

    def test_deploy_preserves_rules_and_installs_font(self):
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('official-rule=native,builtin', (self.prefix / 'user.reg').read_text())
        self.assertNotIn('@current_user@', (self.prefix / 'user.reg').read_text())
        self.assertTrue((self.prefix / 'drive_c/windows/Fonts/wqy-microhei.ttc').is_file())
        self.assertTrue((self.prefix / f'drive_c/users/{pwd.getpwuid(os.getuid()).pw_name}/AppData/Local/Temp').is_dir())
        self.assertIn(str(self.app / 'dlls'), self.trace.read_text())

    def test_update_mode_retargets_builtin_links(self):
        self.assertEqual(self.run_entry().returncode, 0)
        result = self.run_entry('--update')
        self.assertEqual(result.returncode, 0, result.stderr)
        link = self.prefix / 'drive_c/windows/syswow64/kernelbase.dll'
        self.assertEqual(os.readlink(link), str(self.app / 'wine-update/lib/wine/i386-windows/kernelbase.dll'))
        self.assertEqual(self.run_entry().returncode, 0)
        self.assertEqual(os.readlink(link), str(self.app / 'wine/lib/wine/i386-windows/kernelbase.dll'))

    def test_update_retargets_registry_engine_paths(self):
        reg = self.template / 'system.reg'
        unix = str(self.app / 'wine')
        windows = ('Z:' + unix).replace('/', '\\\\')
        reg.write_text(f'engine="{unix}/share/wine"\nfont="{windows}\\\\share\\\\wine"\n')
        self.archive()
        result = self.run_entry('--update')
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.prefix / 'system.reg').read_text()
        self.assertIn(str(self.app / 'wine-update') + '/share/wine', text)
        self.assertIn('wine-update\\\\share', text)
        self.assertEqual(self.run_entry().returncode, 0)
        self.assertNotIn('wine-update', (self.prefix / 'system.reg').read_text())

    def test_legacy_prefix_is_not_modified(self):
        self.prefix.mkdir()
        sentinel = self.prefix / 'keep'
        sentinel.write_text('legacy-data')
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(sentinel.read_text(), 'legacy-data')
        self.assertFalse((self.prefix / 'system.reg').exists())

    def test_invalid_upgrade_keeps_old_program(self):
        self.assertEqual(self.run_entry().returncode, 0)
        (self.app / 'prefix.version').write_text('next\n')
        (self.template / 'drive_c/Program Files (x86)/WXWork/WXWork.exe').unlink()
        self.archive()
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.prefix / 'drive_c/Program Files (x86)/WXWork/WXWork.exe').read_text(), 'program')
        self.assertEqual((self.prefix / 'PACKAGE_VERSION').read_text().strip(), '5.0.13.6005')

    def test_upgrade_preserves_user_data_and_backup(self):
        self.assertEqual(self.run_entry().returncode, 0)
        (self.prefix / 'user-data').write_text('keep')
        (self.app / 'prefix.version').write_text('next\n')
        (self.template / 'drive_c/Program Files (x86)/WXWork/WXWork.exe').write_text('new-program')
        self.archive()
        result = self.run_entry()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.prefix / 'user-data').read_text(), 'keep')
        self.assertEqual((self.prefix / 'drive_c/Program Files (x86)/WXWork/WXWork.exe').read_text(), 'new-program')
        self.assertEqual(len(list((self.prefix / 'drive_c/Program Files (x86)').glob('WXWork.before-package-*'))), 1)

    def test_install_is_explicit_and_uses_update_engine(self):
        installer = self.root / 'official setup.exe'
        installer.write_text('test')
        result = self.run_entry('--install', str(installer))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'{self.app}/wine-update/bin/wine|', self.trace.read_text())
        self.assertIn(str(installer), self.trace.read_text())

    def test_lock_refuses_switch(self):
        import fcntl
        with open(str(self.prefix) + '.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_entry('--update')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.prefix.exists())

    def test_tar_traversal_is_rejected(self):
        with tarfile.open(self.app / 'prefix.tar.xz', 'w:xz') as tar:
            info = tarfile.TarInfo('../escaped')
            info.size = 4
            tar.addfile(info, io.BytesIO(b'evil'))
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'escaped').exists())
        self.assertFalse(self.prefix.exists())

    def test_same_prefix_process_refuses_switch(self):
        env = os.environ.copy()
        env['WINEPREFIX'] = str(self.prefix)
        child = subprocess.Popen([sys.executable, '-I', '-c', 'import sys; print("ready", flush=True); sys.stdin.read()'], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            self.assertEqual(child.stdout.readline().strip(), 'ready')
            result = self.run_entry('--update')
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(self.prefix.exists())
        finally:
            child.communicate(timeout=5)

    def test_relative_symlink_escape_is_rejected(self):
        (self.template / 'outside').symlink_to('../../outside')
        self.archive()
        result = self.run_entry()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.prefix.exists())

    def test_registry_failure_stops_launch(self):
        result = self.run_entry(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('probe', self.trace.read_text())
        self.assertNotIn('WXWork.exe', self.trace.read_text())

    def test_build_uses_bundled_engine_and_single_module_patch(self):
        source = (REPO / 'scripts/build.sh').read_text()
        self.assertIn('ENGINE=$FILES/wine', source)
        self.assertIn('MODULE=lib/wine/i386-windows/kernelbase.dll', source)
        self.assertNotIn('relocate-engine', source)
        self.assertNotIn('/opt/wxwork-wine-bundle10', source)

    def test_postinst_follows_bundled_engine_link(self):
        engine = self.root / 'bundled-engine'
        shutil.move(self.app / 'wine', engine)
        (self.app / 'wine').symlink_to(engine)
        original = self.app / 'wine-orig/lib/wine/i386-windows'
        original.mkdir(parents=True)
        (original / 'kernelbase.dll').write_text('original')
        source = (REPO / 'packaging/DEBIAN/postinst').read_text()
        script = self.root / 'postinst'
        source = source.replace('F=/opt/apps/com.qq.weixin.work.deepin/files', f'F="{self.app}"')
        source = source.replace('COMPAT=/opt/deepin-wine10-stable', f'COMPAT="{self.root / "compat"}"')
        script.write_text(source)
        result = subprocess.run(['sh', str(script), 'configure'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        compat = self.root / 'compat'
        self.assertEqual(os.readlink(compat), str(self.app / 'wine'))
        daily = engine / 'lib/wine/i386-windows/kernelbase.dll'
        update = self.app / 'wine-update/lib/wine/i386-windows/kernelbase.dll'
        self.assertEqual(daily.read_text(), 'wine')
        self.assertEqual(update.read_text(), 'original')
        self.assertNotEqual(daily.stat().st_ino, update.stat().st_ino)
        self.assertTrue((self.app / 'wine-update/bin/wine').is_file())
        self.assertFalse((self.app / 'wine-update').is_symlink())


if __name__ == '__main__':
    unittest.main()
