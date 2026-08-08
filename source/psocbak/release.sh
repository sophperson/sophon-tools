#!/bin/bash
# psocbak 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64（默认，binTools 为 aarch64）；amd64 仅打包脚本
#   VERSION: 显式版本号（默认从 socbak/socbak.sh 提取 v1.2.1）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/psocbak/）
set -uo pipefail

BUILD_RET=0
export CMD_7Z=$(command -v 7z)
export CMD_ZIP=$(command -v zip)

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
VERSION="${2:-$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT_DIR/socbak/socbak.sh" | head -1)}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/psocbak}"

echo "build socbak (arch=$ARCH version=$VERSION) ..."

rm -rf socbak.zip 2>/dev/null
rm -rf output 2>/dev/null
mkdir output

if [ -f "$CMD_7Z" ]; then
	echo "found 7z"
	$CMD_7Z a -mx9 socbak.zip socbak
	BUILD_RET=$?
elif [ -f "$CMD_ZIP" ]; then
	echo "found zip"
	$CMD_ZIP -r -9 socbak.zip socbak
	BUILD_RET=$?
else
	echo "Unsatisfied build dependencies"
	BUILD_RET=-1
fi
cp socbak.zip output/

# 统一接口：汇聚产物到 OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
cp socbak.zip "$OUTPUT_DIR/"

exit $BUILD_RET
