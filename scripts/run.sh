#!/bin/bash
# 用法：run.sh [--update | --install 官方安装包.exe] [客户端参数]
set -euo pipefail

APPDIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
MODE=normal
INSTALLER=
case "${1:-}" in
    --update) MODE=update; shift ;;
    --install)
        MODE=update
        INSTALLER=$(realpath -- "${2:?请指定官方安装包.exe}")
        [ -f "$INSTALLER" ] || { printf '%s\n' '安装包不存在' >&2; exit 1; }
        shift 2
        ;;
esac
WINEDIR="$APPDIR/wine"
[ "$MODE" != update ] || WINEDIR="$APPDIR/wine-update"
WINE="$WINEDIR/bin/wine"
PREFIX=$(realpath -m -- "${WXWORK_PREFIX:-$HOME/.deepinwine/WXWork-official-bundled}")
TARBALL="$APPDIR/prefix.tar.xz"
EXE='C:\Program Files (x86)\WXWork\WXWork.exe'
CURRENT_USER=$(id -un)

log() { printf '[wxwork] %s\n' "$*" >&2; }
notify() { command -v notify-send >/dev/null && notify-send -i com.qq.weixin.work.deepin '企业微信' "$1" || true; }
fail() { log "$*"; notify "$*"; exit 1; }
for tool in python3 flock tar xz realpath; do
    command -v "$tool" >/dev/null || fail "缺少运行工具：$tool"
done
for f in "$WINE" "$APPDIR/dlls/wineserver" "$APPDIR/pre_run.sh" "$APPDIR/font.reg" "$APPDIR/fonts/wqy-microhei.ttc" "$TARBALL" "$APPDIR/prefix.schema" "$APPDIR/prefix.version"; do
    [ -f "$f" ] || fail "缺少包内文件：$f"
done
[ -x "$WINE" ] || fail "Wine 不可执行：$WINE"
SCHEMA=$(<"$APPDIR/prefix.schema")
PKG_VER=$(<"$APPDIR/prefix.version")
[ "$SCHEMA" = official-v1 ] && [ -n "$PKG_VER" ] || fail '模板版本标识无效'

export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLPATH="$WINEDIR/lib:$WINEDIR/lib64"
export WINEPREDLL="$APPDIR/dlls"
export APPRUN_CMD="$WINE" WINE_CMD="$WINE" APPDIR
export DEB_PACKAGE_NAME=com.qq.weixin.work.deepin
export WINE_WMCLASS=com.qq.weixin.work.deepin
export ATTACH_FILE_DIALOG=1 SPECIFY_SHELL_DIR="$APPDIR"
export LANG=zh_CN.UTF-8 LANGUAGE=zh_CN
export WINEDLLOVERRIDES="winemenubuilder.exe=d;${WINEDLLOVERRIDES:-}"
unset WINESERVERSOCKET WINELOADERNOEXEC WINEPRELOADRESERVE

mkdir -p -- "$(dirname -- "$PREFIX")"
exec 9>"${PREFIX}.lock"
flock -n 9 || fail '该容器正在启动或运行，请从托盘完全退出后再切换模式。'

# 检查同前缀的会话，而不是按引擎路径误匹配别的 Wine 应用。
python3 -I - "$PREFIX" <<'PY' || fail '该容器仍有 Wine 进程，请从托盘完全退出并稍后重试。'
import os
from pathlib import Path
import sys
prefix = os.path.realpath(sys.argv[1])
for proc in Path('/proc').iterdir():
    if not proc.name.isdigit() or int(proc.name) in (os.getpid(), os.getppid()):
        continue
    try:
        if proc.stat().st_uid != os.getuid():
            continue
        env = (proc / 'environ').read_bytes().split(b'\0')
        for entry in env:
            if entry.startswith(b'WINEPREFIX=') and os.path.realpath(os.fsdecode(entry[11:])) == prefix:
                raise SystemExit(1)
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        continue
PY

WORK=
cleanup() {
    [ -z "$WORK" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT

extract_template() {
    python3 -I - "$TARBALL" "$APPDIR" <<'PY'
from pathlib import PurePosixPath
import posixpath
import sys
import tarfile
archive, appdir = sys.argv[1:]
engine_roots = tuple(base + '/' + mode + '/' for base in (appdir, '/opt/apps/com.qq.weixin.work.deepin/files') for mode in ('wine', 'wine-update'))
with tarfile.open(archive, 'r:xz') as tar:
    members = tar.getmembers()
    links = set()
    for item in members:
        path = PurePosixPath(item.name)
        if path.is_absolute() or '..' in path.parts or item.isdev() or item.isfifo() or item.islnk():
            raise SystemExit('模板存在不安全条目：' + item.name)
        if item.issym():
            links.add(path)
            target = item.linkname
            if not target.startswith('/'):
                resolved = posixpath.normpath(str(path.parent / target))
                if resolved == '..' or resolved.startswith('../'):
                    raise SystemExit('模板链接越过容器目录：' + item.name)
            if target.startswith('/') and not target.startswith(engine_roots) and target not in ('/', '/dev/null', '/dev/ttyS0'):
                raise SystemExit('模板存在未知绝对链接：' + item.name)
    for item in members:
        if any(p in links for p in PurePosixPath(item.name).parents):
            raise SystemExit('模板条目位于符号链接之下：' + item.name)
PY
    tar -xJf "$TARBALL" -C "$WORK"
    [ -f "$WORK/system.reg" ] && [ -f "$WORK/user.reg" ] \
        && [ -f "$WORK/prefix.schema" ] && [ "$(<"$WORK/prefix.schema")" = "$SCHEMA" ] \
        && [ -f "$WORK/drive_c/Program Files (x86)/WXWork/WXWork.exe" ] \
        || fail '容器模板不完整或布局不匹配'
}

if [ ! -e "$PREFIX" ]; then
    WORK=$(mktemp -d "${PREFIX}.deploy.XXXXXX")
    log '正在部署官方容器模板……'
    extract_template
    python3 -I - "$WORK" "$CURRENT_USER" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
user = sys.argv[2]
old = root / 'drive_c/users/@current_user@'
if not old.is_dir() or old.is_symlink():
    raise SystemExit('模板缺少用户目录')
old.rename(old.with_name(user))
for reg in root.glob('*.reg'):
    reg.write_text(reg.read_text().replace('@current_user@', user))
PY
    printf '%s\n' "$PKG_VER" > "$WORK/PACKAGE_VERSION"
    mv -T -- "$WORK" "$PREFIX"
    WORK=
else
    [ ! -L "$PREFIX" ] && [ -f "$PREFIX/system.reg" ] \
        && [ -f "$PREFIX/prefix.schema" ] && [ "$(<"$PREFIX/prefix.schema")" = "$SCHEMA" ] \
        || fail '容器不是兼容的官方基座布局，已保留原目录。请使用新的 WXWORK_PREFIX。'
    if [ "$(cat "$PREFIX/PACKAGE_VERSION" 2>/dev/null || true)" != "$PKG_VER" ]; then
        WORK=$(mktemp -d "${PREFIX}.upgrade.XXXXXX")
        extract_template
        program="$PREFIX/drive_c/Program Files (x86)/WXWork"
        backup="${program}.before-package-$(date +%Y%m%d%H%M%S)-$$"
        [ ! -L "$program" ] && [ -d "$program" ] || fail '原程序目录无效，未执行升级'
        mv -- "$program" "$backup"
        if ! mv -- "$WORK/drive_c/Program Files (x86)/WXWork" "$program"; then
            mv -- "$backup" "$program"
            fail '替换程序失败，已恢复原程序目录'
        fi
        printf '%s\n' "$PKG_VER" > "$PREFIX/PACKAGE_VERSION"
        log "旧程序保留于 $backup"
        rm -rf -- "$WORK"
        WORK=
    fi
fi

python3 -I - "$PREFIX" "$APPDIR" "$WINEDIR" <<'PY'
from pathlib import Path
import os
import sys
root, app, engine = map(Path, sys.argv[1:])
old_roots = (str(app / 'wine'), str(app / 'wine-update'), '/opt/apps/com.qq.weixin.work.deepin/files/wine', '/opt/apps/com.qq.weixin.work.deepin/files/wine-update', '/opt/deepin-wine10-stable')
for reg in root.glob('*.reg'):
    text = reg.read_text()
    for old in old_roots:
        text = text.replace(old + '/', str(engine) + '/')
        old_win = ('Z:' + old).replace('/', '\\\\')
        new_win = ('Z:' + str(engine)).replace('/', '\\\\')
        text = text.replace(old_win + '\\\\', new_win + '\\\\')
    reg.write_text(text)
for link in root.rglob('*'):
    if not link.is_symlink():
        continue
    target = os.readlink(link)
    for old in old_roots:
        if target.startswith(old + '/'):
            relative = target[len(old) + 1:]
            if '..' in Path(relative).parts:
                raise SystemExit('引擎链接包含非法路径：' + str(link))
            dest = engine / relative
            if not dest.is_file():
                raise SystemExit('引擎链接目标缺失：' + str(dest))
            link.unlink()
            link.symlink_to(dest)
            break
PY
u="$PREFIX/drive_c/users/$CURRENT_USER"
mkdir -p "$u/AppData/Local/Temp" "$u/AppData/Roaming/Microsoft/Windows" "$PREFIX/dosdevices" "$PREFIX/drive_c/windows/Fonts"
for pair in Desktop:DESKTOP Documents:DOCUMENTS Downloads:DOWNLOAD Music:MUSIC Pictures:PICTURES Videos:VIDEOS; do
    name=${pair%%:*}; key=${pair#*:}
    target=$(xdg-user-dir "$key" 2>/dev/null || true)
    [ -n "$target" ] && [ "$target" != "$HOME" ] || target="$HOME/$name"
    if [ -d "$target" ] && { [ -L "$u/$name" ] || [ ! -e "$u/$name" ]; }; then
        ln -sfnT -- "$target" "$u/$name"
    fi
done
for pair in 'c:|../drive_c' "y:|$HOME" 'z:|/'; do
    name=${pair%%|*}; target=${pair#*|}
    [ ! -e "$PREFIX/dosdevices/$name" ] || [ -L "$PREFIX/dosdevices/$name" ] || fail "盘符 $name 不是链接，未覆盖"
    ln -sfnT -- "$target" "$PREFIX/dosdevices/$name"
done
cp --remove-destination -- "$APPDIR/fonts/wqy-microhei.ttc" "$PREFIX/drive_c/windows/Fonts/wqy-microhei.ttc"

# Wine 子进程继承锁，托盘仍在运行时也不能切换模块。
"$WINE" regedit /S "$APPDIR/font.reg"
set +eu
source "$APPDIR/pre_run.sh"
CallPreRun
probe_status=$?
set -eu
[ "$probe_status" -eq 0 ] || fail '官方图形探测未正常结束，请检查容器内的 .glprobe.log'
if [ "$MODE" = update ]; then
    notify '更新兼容模式：内嵌网页可能不可用；新版在线更新仍需验证，完成后请退出并用日常入口重开。'
fi
cd "$PREFIX/drive_c/Program Files (x86)/WXWork"
status=0
if [ -n "$INSTALLER" ]; then
    "$WINE" "$INSTALLER" "$@" || status=$?
else
    args=()
    for a in "$@"; do
        case "$a" in -f|'') ;; *) args+=("$a") ;; esac
    done
    "$WINE" "$EXE" "${args[@]}" || status=$?
fi
"$APPDIR/dlls/wineserver" -w || true
exit "$status"
