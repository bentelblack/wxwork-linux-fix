#!/bin/bash
# Build a self-contained WXWork package from the official Wine and prefix materials.
# Usage: build.sh [WeCom.exe [Wine.deb [WXWork.deb [helper.deb [font.deb]]]]]
set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
READY=$REPO/.ready
BUILD=$REPO/build
WORK=$BUILD/.middle-file
PKG=com.qq.weixin.work.deepin
INST=/opt/apps/$PKG/files
ROOT=$WORK/root
FILES=$ROOT$INST
ENGINE=$FILES/wine
PREFIX=$WORK/prefix
TEMPLATE=$WORK/template
TOOL=$REPO/scripts/prefix-tool.py
BUILDER=$(id -un)

mkdir -p "$REPO/.logs" "$READY" "$BUILD"
LOG=$REPO/.logs/build-$(date +%Y%m%d-%H%M%S)-$$.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1
log() { printf '【%s】%s\n' "$(date '+%F %T')" "$*"; }
log "构建日志：$LOG"
[ "$(id -u)" -ne 0 ] || { printf '%s\n' '请用普通桌面用户构建，不要使用 sudo' >&2; exit 1; }
for command in dpkg-deb fakeroot xz tar apt-get 7z python3 timeout curl sha256sum mktemp flock; do
    command -v "$command" >/dev/null || { printf '缺少构建工具：%s\n' "$command" >&2; exit 1; }
done
[ ! -L "$BUILD" ] || { printf '构建目录不能是符号链接：%s\n' "$BUILD" >&2; exit 1; }
[ ! -L "$BUILD/backup" ] || { printf 'backup 不能是符号链接：%s\n' "$BUILD/backup" >&2; exit 1; }
exec 9>"$BUILD/.build.lock"
flock -n 9 || { printf '%s\n' '已有构建正在使用 build/' >&2; exit 1; }
[ ! -e "$WORK" ] && [ ! -L "$WORK" ] || {
    printf '发现未完成的构建目录：%s（先检查并手动移走，不会自动删除）\n' "$WORK" >&2
    exit 1
}

DOWNLOAD_AGENT='Mozilla/5.0'
DOWNLOAD_REFERER=https://com-store-packages.uniontech.com/
# EXE_URL=https://dldir1.qq.com/wework/work_weixin/WeCom_5.0.12.6026_200003.exe
EXE_URL=https://dldir1.qq.com/wework/work_weixin/WeCom_5.0.13.6005.exe
EXE_NAME=${EXE_URL##*/}
if [ "$#" -gt 5 ]; then
    printf '参数过多：%s\n' "$*" >&2
    exit 2
fi
if [ "$#" -gt 0 ]; then
    if [ -f "$1" ]; then
        EXE=$(realpath -- "$1")
    elif [ -f "$READY/$(basename -- "$1")" ]; then
        EXE=$READY/$(basename -- "$1")
    else
        printf '找不到企业微信 EXE：%s（也未在 .ready/ 找到同名文件）\n' "$1" >&2
        exit 1
    fi
    shift
elif [ -f "$READY/$EXE_NAME" ]; then
    EXE=$READY/$EXE_NAME
    printf '复用 .ready 中的企业微信 EXE：%s\n' "$EXE"
else
    download_dir=$(mktemp -d "$READY/.wecom-download.XXXXXX")
    if ! curl --fail --location --show-error --retry 3 -A "$DOWNLOAD_AGENT" -e "$DOWNLOAD_REFERER" \
        --output "$download_dir/$EXE_NAME" "$EXE_URL"; then
        rm -rf -- "$download_dir"
        exit 1
    fi
    mv -- "$download_dir/$EXE_NAME" "$READY/$EXE_NAME"
    rmdir "$download_dir"
    EXE=$READY/$EXE_NAME
fi
EXE_NAME=$(basename -- "$EXE")
if [[ "$EXE_NAME" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
    VERSION=${BASH_REMATCH[1]}
    DEB_VERSION=$VERSION
else
    VERSION=unknown
    DEB_VERSION=0.0.0.0+unknown
fi
OUT_STEM=${PKG}_${VERSION}_amd64
log "企业微信安装材料：$EXE；包版本：$VERSION"

WINE_NAME=deepin-wine10-stable_10.14deepin14_amd64.deb
APP_NAME=com.qq.weixin.work.deepin_5.0.10.6015deepin3_amd64.deb
HELPER_NAME=deepin-wine-helper_5.4.10-1_amd64.deb
FONT_NAME=fonts-wqy-microhei_0.2.0-beta-4_all.deb
APPSTORE_URL=https://com-store-packages.uniontech.com/appstore/dists/eagle/appstore/binary-amd64/Packages.gz
APPSTORE_INDEX_DIR=
cleanup_index() {
    if [ -n "$APPSTORE_INDEX_DIR" ]; then
        rm -rf -- "$APPSTORE_INDEX_DIR"
        APPSTORE_INDEX_DIR=
    fi
}
trap cleanup_index EXIT
resolve_material() {
    local supplied=$1 expected_filename=$2 package=$3 version=$4 output=$5
    local path=$READY/$expected_filename
    if [ -n "$supplied" ] && [ -f "$supplied" ]; then
        path=$(realpath -- "$supplied")
    elif [ -n "$supplied" ] && [ -f "$READY/$(basename -- "$supplied")" ]; then
        path=$READY/$(basename -- "$supplied")
    elif [ -f "$path" ]; then
        :
    elif [ "$package" = fonts-wqy-microhei ]; then
        local url=https://deb.debian.org/debian/pool/main/f/fonts-wqy-microhei/fonts-wqy-microhei_0.2.0-beta-4_all.deb
        local expected=3fb0ff79033124b863bf9d28af56c62646d5b74774d26be0ce8a5beefe2fed55
        local tmp=$path.part.$$
        printf '从 Debian 官方源下载字体包：%s\n' "$url"
        if ! curl --fail --location --show-error --retry 3 -A "$DOWNLOAD_AGENT" -e "$DOWNLOAD_REFERER" --output "$tmp" "$url"; then
            rm -f -- "$tmp"
            return 1
        fi
        local actual
        actual=$(sha256sum "$tmp" | awk '{print $1}')
        if [ "$actual" != "$expected" ]; then
            rm -f -- "$tmp"
            printf '字体包 SHA-256 不匹配：%s\n' "$actual" >&2
            return 1
        fi
        mv -- "$tmp" "$path"
    else
        if [ -z "$APPSTORE_INDEX_DIR" ]; then
            APPSTORE_INDEX_DIR=$(mktemp -d "$READY/.appstore-index.XXXXXX")
            printf '下载 deepin 官方应用索引：%s\n' "$APPSTORE_URL"
            curl --fail --location --show-error --retry 3 -A "$DOWNLOAD_AGENT" -e "$DOWNLOAD_REFERER" \
                --output "$APPSTORE_INDEX_DIR/Packages.gz" "$APPSTORE_URL"
        fi
        local metadata index_filename sha url tmp actual
        metadata=$(python3 -I - "$APPSTORE_INDEX_DIR/Packages.gz" "$package" "$version" <<'PY'
import gzip, sys
index, package, version = sys.argv[1:]
stanza = {}
with gzip.open(index, 'rt', encoding='utf-8', errors='replace') as stream:
    for line in stream:
        if line == '\n':
            if stanza.get('Package') == package and stanza.get('Version') == version:
                if stanza.get('Architecture') not in ('amd64', 'all'):
                    raise SystemExit('官方索引中的包架构不匹配')
                print(stanza.get('Filename', '') + '\t' + stanza.get('SHA256', ''))
                break
            stanza = {}
        elif line[:1].isspace():
            continue
        elif ': ' in line:
            key, value = line.rstrip('\n').split(': ', 1)
            stanza[key] = value
    else:
        if stanza.get('Package') == package and stanza.get('Version') == version:
            print(stanza.get('Filename', '') + '\t' + stanza.get('SHA256', ''))
        else:
            raise SystemExit(f'官方索引中找不到 {package} {version}')
PY
)
        index_filename=${metadata%%$'\t'*}
        sha=${metadata#*$'\t'}
        [ "$(basename -- "$index_filename")" = "$expected_filename" ] || { printf '官方索引文件名无效：%s\n' "$index_filename" >&2; return 1; }
        [[ "$index_filename" != /* && "$index_filename" != *'..'* ]] || { printf '官方索引返回路径无效\n' >&2; return 1; }
        [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || { printf '官方索引 SHA-256 无效\n' >&2; return 1; }
        url=https://com-store-packages.uniontech.com/appstore/$index_filename
        tmp=$path.part.$$
        printf '从 deepin 官方应用商店下载 %s %s\n' "$package" "$version"
        if ! curl --fail --location --show-error --retry 3 -A "$DOWNLOAD_AGENT" -e "$DOWNLOAD_REFERER" --output "$tmp" "$url"; then
            rm -f -- "$tmp"
            return 1
        fi
        actual=$(sha256sum "$tmp" | awk '{print $1}')
        if [ "$actual" != "$sha" ]; then
            rm -f -- "$tmp"
            printf 'SHA-256 不匹配：期望 %s，实际 %s\n' "$sha" "$actual" >&2
            return 1
        fi
        mv -- "$tmp" "$path"
    fi
    printf '材料 %s：%s\n' "$package" "$path"
    printf -v "$output" '%s' "$path"
}
resolve_material "${1:-}" "$WINE_NAME" deepin-wine10-stable 10.14deepin14 WINE_DEB
resolve_material "${2:-}" "$APP_NAME" com.qq.weixin.work.deepin 5.0.10.6015deepin3 APP_DEB
resolve_material "${3:-}" "$HELPER_NAME" deepin-wine-helper 5.4.10-1 HELPER_DEB
resolve_material "${4:-}" "$FONT_NAME" fonts-wqy-microhei 0.2.0-beta-4 FONT_DEB
cleanup_index

python3 -I - "$WINE_DEB" "$APP_DEB" "$HELPER_DEB" "$FONT_DEB" <<'PY'
import subprocess, sys
expected = ('deepin-wine10-stable', 'com.qq.weixin.work.deepin', 'deepin-wine-helper', 'fonts-wqy-microhei')
for path, package in zip(sys.argv[1:], expected):
    actual = subprocess.check_output(['dpkg-deb', '-f', path, 'Package'], text=True).strip()
    if actual != package:
        raise SystemExit(f'输入 deb 不匹配：{path}: {actual} != {package}')
PY
log '所有构建材料已就绪并完成软件包类型校验'
BUILD_OK=0
PREFIX_ACTIVE=0
WINE_SERVER=
cleanup() {
    local status=$?
    trap - EXIT
    cleanup_index
    if [ "$PREFIX_ACTIVE" = 1 ] && [ -n "$WINE_SERVER" ]; then
        "$WINE_SERVER" -k >/dev/null 2>&1 || true
        timeout 60 "$WINE_SERVER" -w >/dev/null 2>&1 || true
    fi
    if [ "$BUILD_OK" = 1 ]; then
        rm -rf -- "$WORK"
    else
        printf '失败现场保留：%s\n' "$WORK" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir -p -- "$WORK"
step() { log "== [$1/9] $2 =="; }

step 1 '提取配套 Wine、官方应用与辅助组件'
mkdir "$WORK/wine-x" "$WORK/app-x" "$WORK/helper-x" "$ROOT"
dpkg-deb -x "$WINE_DEB" "$WORK/wine-x"
dpkg-deb -x "$APP_DEB" "$WORK/app-x"
dpkg-deb -x "$HELPER_DEB" "$WORK/helper-x"
mkdir -p "$FILES"
cp -a "$WORK/wine-x/opt/deepin-wine10-stable" "$ENGINE"
APP=$WORK/app-x/opt/apps/$PKG/files
HELPER=$WORK/helper-x/opt/deepinwine/tools
[ -f "$APP/files.7z" ] && [ -d "$APP/dlls" ] || { printf '%s\n' '官方企微 deb 缺少 files.7z 或 dlls' >&2; exit 1; }
cp -a "$APP/dlls" "$FILES/dlls"
for file in pre_run.sh win32-test.exe win32_voip_test.exe; do
    [ -f "$APP/$file" ] || { printf '官方运行文件缺失：%s\n' "$file" >&2; exit 1; }
    install -m 755 "$APP/$file" "$FILES/$file"
done
mkdir "$FILES/gl-wine" "$FILES/licenses"
install -m 755 "$HELPER/gl-wine/gl-wine64" "$FILES/gl-wine/gl-wine64"
install -m 644 "$HELPER/gl-wine/gdid3d.reg" "$FILES/gl-wine/gdid3d.reg"
install -m 644 "$WORK/helper-x/usr/share/doc/deepin-wine-helper/copyright" "$FILES/licenses/deepin-wine-helper.copyright"
python3 -I - "$FILES/pre_run.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('/opt/deepinwine/tools/gl-wine', '${APPDIR}/gl-wine')
text = text.replace('if ! ${APPDIR}/gl-wine/gl-wine64 ', 'if ! "${APPDIR}/gl-wine/gl-wine64" ')
text = '\n'.join(line for line in text.splitlines() if not line.lstrip().startswith('pkill -f ')) + '\n'
path.write_text(text)
PY
[ -x "$ENGINE/bin/wine" ] && [ -x "$ENGINE/bin/wineserver" ] || { printf '%s\n' 'Wine 引擎不完整' >&2; exit 1; }
[ -x "$FILES/dlls/wineserver" ] || { printf '%s\n' '官方预加载 wineserver 缺失' >&2; exit 1; }
"$ENGINE/bin/wine" --version

step 2 '基于官方容器提取并部署独立前缀'
python3 -I "$TOOL" extract "$APP/files.7z" "$PREFIX" "$ENGINE"
python3 -I "$TOOL" relocate "$PREFIX" "$ENGINE" "$ENGINE" '@current_user@' "$BUILDER" '' ''
export WINEPREFIX=$PREFIX WINEDEBUG=-all
export WINEDLLPATH="$ENGINE/lib:$ENGINE/lib64"
export WINEDLLOVERRIDES='winemenubuilder.exe=d'
export APPRUN_CMD="$ENGINE/bin/wine" WINE_CMD="$ENGINE/bin/wine" APPDIR=$FILES
export DEB_PACKAGE_NAME=$PKG WINE_WMCLASS=$PKG ATTACH_FILE_DIALOG=1
export LANG=zh_CN.UTF-8 LANGUAGE=zh_CN SPECIFY_SHELL_DIR=$FILES
mkdir -p "$PREFIX/drive_c/users/$BUILDER/AppData/Local/Temp" "$PREFIX/drive_c/windows/Fonts"

step 3 '安装字体并导入登记（原版 Wine 组件）'
mkdir "$WORK/font"
dpkg-deb -x "$FONT_DEB" "$WORK/font"
FONT=$WORK/font/usr/share/fonts/truetype/wqy/wqy-microhei.ttc
[ -s "$FONT" ] || { printf '%s\n' '字体包中缺少 wqy-microhei.ttc' >&2; exit 1; }
mkdir "$FILES/fonts"
install -m 644 "$FONT" "$FILES/fonts/wqy-microhei.ttc"
install -m 644 "$FONT" "$PREFIX/drive_c/windows/Fonts/wqy-microhei.ttc"
install -m 644 "$REPO/packaging/user.reg.append" "$FILES/font.reg"
# This probe/setup uses the engine's built-in wineserver. Do not switch server
# implementations while this prefix remains alive.
WINE_SERVER=$ENGINE/bin/wineserver
PREFIX_ACTIVE=1
env -u WINEPREDLL timeout 120 "$ENGINE/bin/wine" regedit /S "$FILES/font.reg"
"$WINE_SERVER" -k 2>/dev/null || true
timeout 60 "$WINE_SERVER" -w 2>/dev/null || true

step 4 '在同一官方前缀中安装目标企业微信 EXE'
# The tested installer needs the base engine's built-in DLLs. Runtime will
# restore the official WINEPREDLL set; installation and runtime are distinct.
env -u WINEPREDLL timeout 600 "$ENGINE/bin/wine" "$EXE" /S
[ -s "$PREFIX/drive_c/Program Files (x86)/WXWork/WXWork.exe" ] || {
    printf '%s\n' '安装后没有生成 WXWork.exe' >&2
    exit 1
}
"$WINE_SERVER" -k 2>/dev/null || true
timeout 60 "$WINE_SERVER" -w 2>/dev/null || true
PREFIX_ACTIVE=0

step 5 '制作未登录模板并清理临时运行数据'
cp -a "$PREFIX" "$TEMPLATE"
USER_DIR=$TEMPLATE/drive_c/users/$BUILDER
rm -rf -- "$TEMPLATE/.cache" "$USER_DIR/AppData/Local/Temp" \
    "$USER_DIR/AppData/Roaming/Tencent/WXWork/Log" \
    "$USER_DIR/AppData/Roaming/Tencent/WeMail/WeMailBak"
mkdir -p "$USER_DIR/AppData/Local/Temp"
rm -f -- "$TEMPLATE/dosdevices/d::" \
    "$TEMPLATE/.glprobe_sync_v3_done" "$TEMPLATE/.glprobe.log" "$TEMPLATE/.init_d3d" \
    "$TEMPLATE/.libglsoftware" "$TEMPLATE/.libglsoftware_d3d11" \
    "$TEMPLATE/.libglsoftware_voip" "$TEMPLATE/.libgl_need_mesa_vendor"
find "$USER_DIR" -type l -lname "$HOME*" -print -delete

step 6 '重定位模板到安装路径并核对未残留构建机信息'
python3 -I "$TOOL" relocate "$TEMPLATE" "$ENGINE" "$INST/wine" \
    "$BUILDER" '@current_user@' "$PREFIX" "$HOME/.deepinwine/WXWork-official-bundled"
printf '%s\n' official-v1 > "$TEMPLATE/prefix.schema"
printf '%s\n' official-v1 > "$FILES/prefix.schema"
printf '%s\n' "$VERSION" > "$FILES/prefix.version"
python3 -I - "$TEMPLATE" "$WORK" "$BUILDER" <<'PY'
from pathlib import Path
import os, re, sys
root, work, user = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
for reg in root.glob('*.reg'):
    text = reg.read_text(errors='replace')
    if work in text or re.search(r'(?<![\w@])' + re.escape(user) + r'(?![\w@])', text):
        raise SystemExit(f'模板注册表残留构建路径或用户名：{reg}')
for current, dirs, files in os.walk(root, followlinks=False):
    for name in dirs + files:
        entry = Path(current) / name
        if entry.is_symlink() and work in os.readlink(entry):
            raise SystemExit(f'模板符号链接残留构建路径：{entry}')
print('模板路径、用户占位符检查通过')
PY

step 7 '仅替换日常引擎的 i386 kernelbase 并校验单文件差异'
MODULE=lib/wine/i386-windows/kernelbase.dll
ORIGINAL=$FILES/wine-orig/$MODULE
mkdir -p "$(dirname -- "$ORIGINAL")"
cp -p "$ENGINE/$MODULE" "$ORIGINAL"
install -m "$(stat -c '%a' "$ENGINE/$MODULE")" "$FILES/dlls/i386-windows/kernelbase.dll" "$ENGINE/$MODULE"
python3 -I - "$WORK/wine-x/opt/deepin-wine10-stable" "$ENGINE" "$MODULE" <<'PY'
from pathlib import Path
import hashlib, os, sys
base, built, expected = map(Path, sys.argv[1:])
base_paths, built_paths = set(), set()
def collect(root, found):
    for current, dirs, files in os.walk(root, followlinks=False):
        for name in dirs + files:
            path = Path(current) / name
            found.add(path.relative_to(root))
collect(base, base_paths)
collect(built, built_paths)
if base_paths != built_paths:
    missing = sorted(str(p) for p in base_paths - built_paths)
    extra = sorted(str(p) for p in built_paths - base_paths)
    raise SystemExit(f'引擎目录结构变化：missing={missing[:8]} extra={extra[:8]}')
differences = []
for rel in sorted(base_paths):
    source, target = base / rel, built / rel
    if source.is_symlink():
        if not target.is_symlink() or os.readlink(source) != os.readlink(target):
            raise SystemExit(f'引擎符号链接变化：{rel}')
    elif source.is_file():
        if not target.is_file() or hashlib.sha256(source.read_bytes()).digest() != hashlib.sha256(target.read_bytes()).digest():
            differences.append(rel)
if differences != [expected]:
    raise SystemExit('引擎差异不符合单模块约束：' + repr([str(p) for p in differences]))
print('校验通过：日常引擎仅 i386 kernelbase.dll 与原版不同')
PY

step 8 '组装 deb 文件系统与官方前缀模板'
mkdir -p "$ROOT/DEBIAN" "$ROOT/usr/share/applications" "$ROOT/usr/share/icons/hicolor/48x48/apps"
cp "$REPO/packaging/DEBIAN/postinst" "$REPO/packaging/DEBIAN/prerm" "$ROOT/DEBIAN/"
sed "s/@VERSION@/$DEB_VERSION/" "$REPO/packaging/DEBIAN/control" > "$ROOT/DEBIAN/control"
chmod 755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm"
install -m 755 "$REPO/scripts/run.sh" "$FILES/run.sh"
cp "$REPO/packaging/$PKG.desktop" "$ROOT/usr/share/applications/"
cp "$WORK/app-x/opt/apps/$PKG/entries/icons/hicolor/48x48/apps/$PKG.svg" "$ROOT/usr/share/icons/hicolor/48x48/apps/"
( cd "$TEMPLATE" && tar --numeric-owner --owner=0 --group=0 -cf - . | xz -T0 -6 > "$FILES/prefix.tar.xz" )
xz -t "$FILES/prefix.tar.xz"
[ -d "$FILES/wine" ] && [ ! -L "$FILES/wine" ] || { printf '%s\n' '包内 wine 必须是直接目录，不允许外置绝对链接' >&2; exit 1; }
[ -x "$FILES/wine/bin/wine" ] && [ -x "$FILES/dlls/wineserver" ] || { printf '%s\n' '包内 Wine 运行入口不完整' >&2; exit 1; }
[ -s "$FILES/wine-orig/$MODULE" ] || { printf '%s\n' '缺少原版 kernelbase 备份' >&2; exit 1; }
chmod -R go-w "$ROOT"
size=$(du -sk "$ROOT" --exclude=DEBIAN | cut -f1)
sed -i "s/^Installed-Size: .*/Installed-Size: $size/" "$ROOT/DEBIAN/control"
[ -z "$(find "$ROOT" -type f -links +1 -print -quit)" ] || { printf '%s\n' 'deb 解包目录包含硬链接' >&2; exit 1; }

step 9 '构建并验证两个修复变体后发布'
for variant in fixed-webview fixed-webview-level; do
    if [ "$variant" = fixed-webview-level ]; then
        install -m 755 "$REPO/scripts/wxwork-window-stack.py" "$FILES/wxwork-window-stack.py"
        summary='Tencent WXWork with webview and window stacking fixes'
    else
        summary='Tencent WXWork with webview fix'
    fi
    sed -e "s/@VERSION@/$DEB_VERSION/" \
        -e "s/^Description:.*/Description: $summary/" \
        "$REPO/packaging/DEBIAN/control" > "$ROOT/DEBIAN/control"
    printf 'X-WXWork-Fix: %s\n' "$variant" >> "$ROOT/DEBIAN/control"
    size=$(du -sk "$ROOT" --exclude=DEBIAN | cut -f1)
    sed -i "s/^Installed-Size: .*/Installed-Size: $size/" "$ROOT/DEBIAN/control"
    name=$OUT_STEM.$variant.deb
    PACKAGE=$WORK/$name
    fakeroot dpkg-deb -Zxz -b "$ROOT" "$PACKAGE"
    [ "$(dpkg-deb -f "$PACKAGE" Package)" = "$PKG" ] \
        && [ "$(dpkg-deb -f "$PACKAGE" Version)" = "$DEB_VERSION" ] \
        && [ "$(dpkg-deb -f "$PACKAGE" X-WXWork-Fix)" = "$variant" ] \
        || { printf '%s\n' 'deb 元数据不匹配' >&2; exit 1; }
    CHECK=$WORK/package-check
    mkdir "$CHECK"
    dpkg-deb -x "$PACKAGE" "$CHECK"
    mkdir "$CHECK/DEBIAN"
    dpkg-deb -e "$PACKAGE" "$CHECK/DEBIAN"
    CHECK_FILES=$CHECK$INST
    [ -d "$CHECK_FILES/wine" ] && [ ! -L "$CHECK_FILES/wine" ] \
        && [ -x "$CHECK_FILES/wine/bin/wine" ] \
        && [ -s "$CHECK_FILES/dlls/wineserver" ] \
        && [ -x "$CHECK_FILES/run.sh" ] \
        || { printf '%s\n' 'deb 内运行文件检查失败' >&2; exit 1; }
    if [ "$variant" = fixed-webview-level ]; then
        [ -x "$CHECK_FILES/wxwork-window-stack.py" ] || { printf '%s\n' '层级修复辅助程序缺失' >&2; exit 1; }
    else
        [ ! -e "$CHECK_FILES/wxwork-window-stack.py" ] || { printf '%s\n' '网页修复包不应包含层级辅助程序' >&2; exit 1; }
    fi
    grep -Fq 'COMPAT=/opt/deepin-wine10-stable' "$CHECK/DEBIAN/postinst" \
        && grep -Fq 'ln -s "$F/wine" "$COMPAT"' "$CHECK/DEBIAN/postinst" \
        || { printf '%s\n' 'postinst 兼容链接配置缺失' >&2; exit 1; }
    rm -rf -- "$CHECK"
    ( cd "$WORK" && sha256sum "$name" > "$name.sha256" && sha256sum -c "$name.sha256" )
    if apt-get install -s "$PACKAGE" > "$WORK/apt-$variant.txt" 2>&1; then
        grep -E '^(Inst|Conf)' "$WORK/apt-$variant.txt" || true
    else
        printf '提示：apt 依赖模拟失败；详见 %s\n' "$WORK/apt-$variant.txt"
    fi
done

STAMP=$(date +%Y%m%d-%H%M%S-%N)
mkdir -p "$BUILD/backup"
for variant in fixed-webview fixed-webview-level; do
    OUT=$BUILD/$OUT_STEM.$variant.deb
    for old in "$OUT" "$OUT.sha256"; do
        [ -e "$old" ] || [ -L "$old" ] || continue
        name=$(basename -- "$old")
        saved=$BUILD/backup/$name-$STAMP
        [ ! -e "$saved" ] && [ ! -L "$saved" ] || { printf '备份文件已存在：%s\n' "$saved" >&2; exit 1; }
        mv -- "$old" "$saved"
        printf '已备份同版本旧产物：%s -> %s\n' "$old" "$saved"
    done
done
for variant in fixed-webview fixed-webview-level; do
    name=$OUT_STEM.$variant.deb
    mv -- "$WORK/$name" "$WORK/$name.sha256" "$BUILD/"
    ( cd "$BUILD" && sha256sum -c "$name.sha256" )
    ls -lh "$BUILD/$name" "$BUILD/$name.sha256"
done
BUILD_OK=1
