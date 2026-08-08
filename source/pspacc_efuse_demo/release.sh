#!/bin/bash
# pspacc_efuse_demo 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    amd64|arm64（默认 amd64；arm64 走交叉编译）
#   VERSION: 无版本号（保留参数兼容）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pspacc_efuse_demo/）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pspacc_efuse_demo}"

echo "==> pspacc_efuse_demo gcc 编译 arch=$ARCH"
mkdir -p "$OUTPUT_DIR"

case "$ARCH" in
  amd64)
    gcc spacc_efuse_demo.c -o "$OUTPUT_DIR/spacc_efuse_demo"
    ;;
  arm64)
    CC="${CC:-aarch64-linux-gnu-gcc}"
    if ! command -v "$CC" >/dev/null 2>&1; then
      echo "ERROR: 交叉编译器 $CC 不可用" >&2; exit 1
    fi
    "$CC" -march=armv8-a spacc_efuse_demo.c -o "$OUTPUT_DIR/spacc_efuse_demo"
    ;;
  *)
    echo "ERROR: ARCH 必须是 amd64|arm64" >&2; exit 1 ;;
esac

chmod +x "$OUTPUT_DIR/spacc_efuse_demo"
file "$OUTPUT_DIR/spacc_efuse_demo" | head -1
echo "==> pspacc_efuse_demo 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
