#!/bin/bash
# pota_update 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64（默认，设备）；amd64 时仅打包脚本不交叉编译
#   VERSION: 显式版本号（默认 1.0.0，本项目原无版本号）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pota_update/）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
VERSION="${2:-1.0.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pota_update}"

case "$ARCH" in
  arm64|amd64) ;;
  *) echo "ERROR: ARCH 必须是 arm64|amd64，得到: $ARCH" >&2; exit 1 ;;
esac

echo "==> pota_update build arch=$ARCH version=$VERSION"
rm -rf output 2>/dev/null || true
mkdir -p output

# 主脚本（release 产物名为 ota_update.sh，源码文件为 ota.sh）
cp ota.sh output/ota_update.sh
cp ota.sh output/ota.sh
# 附加脚本与 arm64 二进制
cp get_network_info.sh output/ 2>/dev/null || true
if [ "$ARCH" = "arm64" ]; then
  cp -r arm64_bin output/ 2>/dev/null || true
fi

mkdir -p "$OUTPUT_DIR"
cp -r output/* "$OUTPUT_DIR/"
echo "==> pota_update 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
