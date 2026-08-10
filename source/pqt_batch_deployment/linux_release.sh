#!/bin/bash
# pqt_batch_deployment linux AppImage 构建（M3 统一构建）
# 用法: bash linux_release.sh [WORK_DIR] [VERSION]
#   WORK_DIR: 构建工作目录（中间产物 + AppImage 只写这里，默认 $PWD/.build）
#   VERSION:  显式版本号（默认从 CMakeLists MY_PROJECT_VERSION 解析）
# out-of-source 构建：源码目录零改动，产物与中间文件全部落在 WORK_DIR。
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

# 并行构建 no_ui 与 GUI（out-of-source：build 目录在 WORK_DIR 下，产物收拢到 WORK_DIR/build/<名>）
function updateFun(){
    local name="$1" src="$2"
    echo "========================================"
    echo "need build $name"
    local bdir="$WORK_DIR/$name"
    mkdir -p "$bdir"
    (cd "$src" && cmake -B "$bdir" -DMY_PROJECT_VERSION="${VERSION}" -DCMAKE_BUILD_TYPE=Release)
    cmake --build "$bdir" -j"$(nproc)"
    cmake --install "$bdir"
    mkdir -p "$WORK_DIR/build/$name"
    cp -a "$bdir/output/"* "$WORK_DIR/build/$name/"
}
updateFun qt_batch_deployment_no_ui "no_ui" &
updateFun qt_batch_deployment "." &
wait

pushd "$WORK_DIR/build" >/dev/null
cp "${SOURCE_ROOT}/libs/Appdir" ./ -a
cp ${SOURCE_ROOT}/libs/$host_inf/openssl/lib/*.so.* Appdir/usr/lib
cp ${SOURCE_ROOT}/libs/$host_inf/release/lib/*.so.* Appdir/usr/lib
# no_ui 的 CMake 产物名为 no_ui，需改名；run.sh 按 qt_batch_deployment[_no_ui] 分发
cp qt_batch_deployment/qt_batch_deployment Appdir/usr/bin/qt_batch_deployment
cp qt_batch_deployment_no_ui/no_ui Appdir/usr/bin/qt_batch_deployment_no_ui
sed -i "s/Name=qt_batch_deployment/Name=qt_batch_deployment_${VERSION}/" Appdir/qt_batch_deployment.desktop
mkdir bintools
cp "${SOURCE_ROOT}/libs/$host_inf/appimagetool" bintools/
chmod +x bintools/appimagetool
cp "${SOURCE_ROOT}/libs/linuxdeployqt.tar.gz" bintools/
tar -xaf bintools/linuxdeployqt.tar.gz -C bintools
pushd bintools/linuxdeployqt-continuous >/dev/null
qmake -config release
make -j"$(nproc)"
popd >/dev/null # linuxdeployqt-continuous
# linuxdeployqt 用 -bundle-non-qt-libs 只做依赖收集（不 -appimage 打包），
# 避免同一 AppDir 被打出多份 AppImage（-appimage 会附加 git hash 到文件名）。
# 最终 AppImage 由下方手动 appimagetool 一次性生成（no_ui 不作为独立产物，见 MYSWY 决定）。
export PATH="$WORK_DIR/build/bintools:$PATH"
./bintools/linuxdeployqt-continuous/bin/linuxdeployqt Appdir/qt_batch_deployment.desktop -bundle-non-qt-libs -verbose=2 || true
sed -i "s/Exec=qt_batch_deployment/Exec=qt_batch_deployment_run.sh/" Appdir/qt_batch_deployment.desktop
rm Appdir/qt_batch_deployment_no_ui.desktop
rm Appdir/qt_batch_deployment_no_ui.png
pushd Appdir >/dev/null
rm AppRun
ln -s usr/bin/qt_batch_deployment_run.sh ./AppRun
popd >/dev/null # Appdir
./bintools/appimagetool --comp xz Appdir
cp ./*.AppImage "${WORK_DIR}"/
popd >/dev/null # build

file_path=$(find "${WORK_DIR}" -maxdepth 1 -name "qt_batch_deployment*.AppImage" ! -name "*no_ui*" -print -quit)
if [ -z "$file_path" ]; then
    echo "ERROR: 未生成 AppImage" >&2
    exit 1
fi
file_size=$(stat -c %s "$file_path")
file_size_kb=$((file_size / 1024))
if [ $file_size_kb -gt $(( 23 * 1024 )) ]; then
    echo "AppImage size ${file_size_kb}KiB ok"
    exit 0
else
    echo "AppImage size ${file_size_kb}KiB error" >&2
    exit 1
fi