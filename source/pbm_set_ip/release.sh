#!/bin/bash
# pbm_set_ip 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64 | amd64 | all（默认 arm64，musl 全静态）
#   VERSION: 显式版本号（默认从 git describe 生成 v<tag>-<sha>-<ts>）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pbm_set_ip/）
#   env BM_SET_IP_GIT_VERSION: 注入编译时版本（默认取 git describe，避免改写仓库跟踪文件）
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

# 编译时版本通过 env 注入，不改写仓库跟踪的 bm_set_ip/.git_version 文件——
# 该文件是仓库跟踪文件，若在镜像内构建时改写会弄脏工作区（MYS-58 S-2）。
# build.rs 优先读 BM_SET_IP_GIT_VERSION，空时回退到 .git_version 的已提交值。
export BM_SET_IP_GIT_VERSION="$VERSION"

for target in $TARGETS; do
  echo "==> cargo build --target $target --release"
  (cd "$CARGO_DIR" && cargo build --target "$target" --release)
  local_bin="$CARGO_DIR/target/${target}/release/bm_set_ip"
  if [ ! -f "$local_bin" ]; then
    echo "ERROR: 未找到产物 $local_bin" >&2
    exit 1
  fi
  file "$local_bin" | head -1
  # 架构命名统一用 M1 规范的 arm64/amd64 口径（aarch64→arm64、x86_64→amd64），
  # 不要用 ${target%%-*} 直接截取（会得到 aarch64/x86_64，与全仓命名不一致）。
  case "$target" in
    aarch64-*) arch_suffix="arm64" ;;
    x86_64-*)  arch_suffix="amd64" ;;
    *) echo "ERROR: 未知 target '$target'，无法映射架构后缀" >&2; exit 1 ;;
  esac
  # upx 仅 4.x+ 支持压缩 static-pie 产物（arm64 musl 静态 / amd64 static-pie）。
  # 旧版 upx 3.x（如 ubuntu 仓库 upx-ucl 3.95）对 static-pie 直接报 not supported，
  # 若静默吞掉会导致同一脚本在不同环境产物体积漂移（MYS-58 O-2）。
  if command -v upx >/dev/null 2>&1; then
    upx_major="$(upx --version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1)"
    if [ -n "$upx_major" ] && [ "$upx_major" -ge 4 ] 2>/dev/null; then
      echo "==> upx $upx_major.x 压缩 $local_bin"
      if ! upx -9 --best --nrv2b --no-color "$local_bin" >/dev/null 2>&1; then
        echo "WARN: upx 压缩 $local_bin 失败（产物未压缩，功能不受影响）" >&2
      fi
    else
      echo "WARN: upx 版本过旧（$(upx --version 2>/dev/null | head -1)），不支持压缩 static-pie 产物，跳过压缩（若要压缩请用 upx 4.x+）" >&2
    fi
  else
    echo "WARN: 未找到 upx，跳过压缩" >&2
  fi
  cp "$local_bin" "$OUTPUT_DIR/bm_set_ip_${arch_suffix}_musl"
done

# bm_set_ip_auto 是配网自动脚本（bm_set_ip eth0 dhcp 包装），被其他子项目引用安装到
# /usr/sbin/bm_set_ip_auto，随产物一起发布（MYS-58 S-4）。
if [ -f "$CARGO_DIR/bm_set_ip_auto" ]; then
  cp "$CARGO_DIR/bm_set_ip_auto" "$OUTPUT_DIR/bm_set_ip_auto"
  chmod +x "$OUTPUT_DIR/bm_set_ip_auto"
fi

echo "==> pbm_set_ip 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
