#!/bin/bash
# pget_info 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    amd64|arm64|all（默认 amd64；纯脚本，架构仅作标识）
#   VERSION: 显式版本号（默认从 get_info.sh 提取）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pget_info/）
set -uo pipefail

BUILD_RET=0
export CMD_7Z=$(command -v 7z)
export CMD_ZIP=$(command -v zip)

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-amd64}"
VERSION="${2:-$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$SCRIPT_DIR/get_info.sh" | head -1)}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pget_info}"

echo "build get_info (arch=$ARCH version=$VERSION) ..."

rm -rf output
mkdir -p output/get_info
cp get_info.sh output/get_info/
cp get_info_log_to_png.* output/get_info/

pushd output
	if [ -f "$CMD_7Z" ]; then
		echo "found 7z"
		$CMD_7Z a -mx9 get_info.zip get_info
		BUILD_RET=$?
	elif [ -f "$CMD_ZIP" ]; then
		echo "found zip"
		$CMD_ZIP -r -9 get_info.zip get_info
		BUILD_RET=$?
	else
		echo "Unsatisfied build dependencies"
		BUILD_RET=-1
	fi
popd

# 统一接口：汇聚产物到 OUTPUT_DIR
mkdir -p "$OUTPUT_DIR"
cp output/get_info.zip "$OUTPUT_DIR/"

exit $BUILD_RET
