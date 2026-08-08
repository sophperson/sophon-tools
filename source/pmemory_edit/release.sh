#!/bin/bash
# pmemory_edit 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64（默认，bintools 为 aarch64）；amd64 仅打包
#   VERSION: 显式版本号（默认从 source/memory_edit/memory_edit.sh 提取 2.12）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pmemory_edit/）
set -uo pipefail

BUILD_RET=0

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
MEMORY_EDIT_VERSION="${2:-$(grep "INFO: version: " "$SCRIPT_DIR/source/memory_edit/memory_edit.sh" | awk -F' ' '{print $(NF)}' | tr -d '"')}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pmemory_edit}"

export CMD_DPKG_DEB=$(command -v dpkg-deb)

echo "build memory_edit (arch=$ARCH version=${MEMORY_EDIT_VERSION}) ..."

rm -rf memory_edit*.tar.xz 2>/dev/null
rm -rf output 2>/dev/null
mkdir output
if [ -f "$CMD_DPKG_DEB" ]; then
	rm -rf *.deb
	rm -rf *.tar.xz
	pushd source
		tar -caf ../memory_edit_v${MEMORY_EDIT_VERSION}.tar.xz memory_edit
		cp ../memory_edit_v${MEMORY_EDIT_VERSION}.tar.xz deb/opt/sophon/memory_edit.tar.xz
		cp deb/DEBIAN/control ./control.bak
		sed -i "s/MEMORY_EDIT_VERSION/$MEMORY_EDIT_VERSION/" deb/DEBIAN/control
		echo "deb build version: v${MEMORY_EDIT_VERSION}"
		$CMD_DPKG_DEB -b deb ../memory_edit_v${MEMORY_EDIT_VERSION}.deb
		mv ./control.bak deb/DEBIAN/control
	popd
else
	echo "Unsatisfied build dependencies"
	BUILD_RET=-1
fi
cp memory_edit*.tar.xz output/
cp memory_edit*.deb output/

# 统一接口：汇聚产物到 OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
cp memory_edit*.tar.xz memory_edit*.deb "$OUTPUT_DIR/"

exit $BUILD_RET
