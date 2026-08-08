#!/bin/bash
# psoph_phytool 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    all（默认，通用脚本，无编译）
#   VERSION: 无版本号（保留参数兼容）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/psoph_phytool/）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/psoph_phytool}"

echo "==> psoph_phytool 纯脚本拷贝（无编译）"
mkdir -p "$OUTPUT_DIR"
cp sophon_phytool.sh "$OUTPUT_DIR/"
chmod +x "$OUTPUT_DIR/sophon_phytool.sh"
echo "==> psoph_phytool 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
