#!/bin/bash
# pmem_aging_test 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64（默认，设备侧现场编译）；amd64 仅打包
#   VERSION: 显式版本号（默认从 memtest_a53_gdma/start.sh 提取 V1.4.1）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pmem_aging_test/）
set -uo pipefail

BUILD_RET=0
export CMD_7Z=$(command -v 7z)
export CMD_ZIP=$(command -v zip)

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
VERSION="${2:-$(grep -r "MEMTEST VERSION:" "$SCRIPT_DIR/memtest_a53_gdma/start.sh" | awk '{print $(NF)}' | tr -d '"')}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pmem_aging_test}"

echo "build memtest_a53_gdma ${VERSION} (arch=$ARCH) ..."

rm -rf output
mkdir -p output
cp -r memtest_a53_gdma output/mem_aging_test_${VERSION}
cp *.md output

pushd output
	if [ -f "$CMD_7Z" ]; then
		echo "found 7z"
		$CMD_7Z a -mx9 mem_aging_test_${VERSION}.zip mem_aging_test_${VERSION}
		BUILD_RET=$?
	elif [ -f "$CMD_ZIP" ]; then
		echo "found zip"
		$CMD_ZIP -r -9 mem_aging_test_${VERSION}.zip mem_aging_test_${VERSION}
		BUILD_RET=$?
	else
		echo "Unsatisfied build dependencies"
		BUILD_RET=-1
	fi
popd

# 统一接口：汇聚产物到 OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
cp output/mem_aging_test_${VERSION}.zip "$OUTPUT_DIR/"

exit $BUILD_RET
