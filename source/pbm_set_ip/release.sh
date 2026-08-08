#!/bin/bash
# pbm_set_ip 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64 | amd64 | all（默认 arm64，musl 全静态）
#   VERSION: 显式版本号（默认从 git describe 生成 v<tag>-<sha>-<ts>）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pbm_set_ip/）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pbm_set_ip}"

# Cargo 工程位于 bm_set_ip/ 子目录（官方 build.sh 同布局）
CARGO_DIR="$SCRIPT_DIR/bm_set_ip"

case "$ARCH" in
  arm64) TARGETS="aarch64-unknown-linux-musl" ;;
  amd64) TARGETS="x86_64-unknown-linux-musl" ;;
  all)   TARGETS="aarch64-unknown-linux-musl x86_64-unknown-linux-musl" ;;
  *) echo "ERROR: ARCH 必须是 arm64|amd64|all，得到: $ARCH" >&2; exit 1 ;;
esac

VERSION="${2:-$(git -C "$SCRIPT_DIR" describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)-$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)-$(date -u '+%Y%m%d_%H%M%S')}"

mkdir -p "$OUTPUT_DIR"
echo "==> pbm_set_ip version=$VERSION"

# 记录版本（对齐官方 build.sh 的 .git_version 行为）。
# 注意: 该文件是仓库跟踪文件，仅在能取到真实 git 信息时更新，避免提交垃圾版本号。
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  echo "$VERSION" > "$CARGO_DIR/.git_version"
fi

for target in $TARGETS; do
  echo "==> cargo build --target $target --release"
  (cd "$CARGO_DIR" && cargo build --target "$target" --release)
  local_bin="$CARGO_DIR/target/${target}/release/bm_set_ip"
  if [ ! -f "$local_bin" ]; then
    echo "ERROR: 未找到产物 $local_bin" >&2
    exit 1
  fi
  file "$local_bin" | head -1
  arch_suffix="${target%%-*}"
  if command -v upx >/dev/null 2>&1; then
    upx -9 --best --nrv2b --no-color "$local_bin" >/dev/null 2>&1 || true
  fi
  cp "$local_bin" "$OUTPUT_DIR/bm_set_ip_${arch_suffix}_musl"
done

echo "==> pbm_set_ip 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
