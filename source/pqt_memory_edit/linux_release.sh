#!/bin/bash
# pqt_memory_edit linux AppImage 构建（M3 统一构建）
# 用法: bash linux_release.sh [WORK_DIR] [VERSION]
#   WORK_DIR: 构建工作目录（中间产物 + AppImage 只写这里，默认 $PWD/.build）
#   VERSION:  显式版本号（默认从 CMakeLists MY_PROJECT_VERSION 解析）
# out-of-source 构建：源码目录零改动，产物与中间文件全部落在 WORK_DIR。
# 任一步失败立即退出（set -euo pipefail），不再靠 AppImage 大小兜底。
set -euo pipefail

get_arch=$(arch)
host_inf=""
if [[ $get_arch =~ "x86_64" ]]; then
    echo "this is x86_64"
    host_inf="linux_amd64"
elif [[ $get_arch =~ "aarch64" ]]; then
    echo "this is arm64"
    host_inf="linux_arm64"
else
    echo "unknown arch: $get_arch" >&2
    exit 1
fi

SOURCE_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
WORK_DIR="${1:-$SOURCE_ROOT/.build}"
VERSION="${2:-$(grep -E 'set\(MY_PROJECT_VERSION "[^"]+"\)' "$SOURCE_ROOT/CMakeLists.txt" | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+')}"
if [ -z "$VERSION" ]; then
    echo "ERROR: 无法从 CMakeLists.txt 解析版本号，请显式传入 VERSION" >&2
    exit 1
fi
echo "need build version: ${VERSION}"

# WORK_DIR 可能是 docker 挂载点，不能 rm 目录本身，只清空内容
rm -rf "$WORK_DIR"/* "$WORK_DIR"/.[!.]* 2>/dev/null || true
mkdir -p "$WORK_DIR"

echo "==> cmake 配置 + 编译 (out-of-source, 版本 ${VERSION}) ..."
cmake -S "$SOURCE_ROOT" -B "$WORK_DIR/build" -DMY_PROJECT_VERSION="${VERSION}" -DCMAKE_BUILD_TYPE=Release
cmake --build "$WORK_DIR/build" -j"$(nproc)"
cmake --install "$WORK_DIR/build"

echo "==> 组装 AppDir 并打包 AppImage ..."
mkdir -p "$WORK_DIR/appimage"
cp "$SOURCE_ROOT/libs/Appdir" "$WORK_DIR/appimage/" -a
cp "$SOURCE_ROOT/libs/$host_inf/openssl/lib/"*.so.* "$WORK_DIR/appimage/Appdir/usr/lib"
cp "$SOURCE_ROOT/libs/$host_inf/release/lib/"*.so.* "$WORK_DIR/appimage/Appdir/usr/lib"
cp "$WORK_DIR/build/output/qt_mem_edit" "$WORK_DIR/appimage/Appdir/usr/bin"
# 产物名由桌面文件 Name 决定，写进版本号使显式 VERSION 生效
sed -i "s/Name=qt_mem_edit/Name=qt_mem_edit_V${VERSION}/" "$WORK_DIR/appimage/Appdir/qt_mem_edit.desktop"
mkdir -p "$WORK_DIR/appimage/bintools"
cp "$SOURCE_ROOT/libs/$host_inf/appimagetool" "$WORK_DIR/appimage/bintools/"
chmod +x "$WORK_DIR/appimage/bintools/appimagetool"
cp "$SOURCE_ROOT/libs/linuxdeployqt.tar.gz" "$WORK_DIR/appimage/bintools/"
tar -xaf "$WORK_DIR/appimage/bintools/linuxdeployqt.tar.gz" -C "$WORK_DIR/appimage/bintools"

pushd "$WORK_DIR/appimage" >/dev/null
# linuxdeployqt 为源码包，需现场 qmake+make；编译/运行失败即退出，
# 否则 AppImage 缺 Qt 库且不报错（依赖库收集由它完成）。
# 用 -bundle-non-qt-libs 只做依赖收集（不 -appimage 打包），
# 最终 AppImage 由下方手动 appimagetool 一次性生成，避免同一 AppDir 打出两份。
(cd bintools/linuxdeployqt-continuous && qmake linuxdeployqt.pro && make -j"$(nproc)")
export PATH="$PWD/bintools:$PATH"
./bintools/linuxdeployqt-continuous/bin/linuxdeployqt Appdir/qt_mem_edit.desktop -bundle-non-qt-libs -verbose=2
./bintools/appimagetool --comp xz Appdir
cp ./*.AppImage "$WORK_DIR"/
popd >/dev/null # appimage

file_path=$(find "$WORK_DIR" -maxdepth 1 -name '*.AppImage' -print -quit)
if [ -z "$file_path" ]; then
    echo "ERROR: 未生成 AppImage" >&2
    exit 1
fi
file_size=$(stat -c %s "$file_path")
file_size_kb=$((file_size / 1024))
if [ $file_size_kb -gt $(( 20 * 1024 )) ]; then
    echo "AppImage size ${file_size_kb}KiB ok"
    exit 0
else
    echo "AppImage size ${file_size_kb}KiB error" >&2
    exit 1
fi
