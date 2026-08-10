#!/bin/bash
# pqt_memory_edit 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    amd64 | arm64 | linux（默认 amd64；linux AppImage 为宿主架构，见下）
#            windows=Windows exe 交叉编译
#   VERSION: 显式版本号（默认从 CMakeLists MY_PROJECT_VERSION 解析）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pqt_memory_edit/）
# 说明: linux AppImage 走 docker/pqt 镜像（glibc≤2.31），windows exe 走 sophon-tools-build mingw。
#       AppImage 的 linuxdeployqt/appimagetool 为宿主架构预编译二进制，无法交叉：
#       ARCH=amd64 要求构建宿主为 x86_64，ARCH=arm64 要求宿主为 aarch64，否则报错退出。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pqt_memory_edit}"

VERSION="${2:-$(grep -E 'set\(MY_PROJECT_VERSION "[^"]+"\)' "$SCRIPT_DIR/CMakeLists.txt" | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+')}"
if [ -z "$VERSION" ]; then
  echo "ERROR: 无法从 CMakeLists.txt 解析版本号，请显式传入 VERSION" >&2
  exit 1
fi
echo "==> pqt_memory_edit version=$VERSION arch=$ARCH"

mkdir -p "$OUTPUT_DIR"

# ARCH 必须真实影响构建：AppImage 工具链绑定宿主架构，无法交叉。
# amd64/arm64 分别要求 x86_64/aarch64 宿主；linux 按宿主自动选择。
build_linux() {
  local want_arch="$1"
  local host_arch
  host_arch="$(arch 2>/dev/null || uname -m)"
  case "$want_arch" in
    amd64)
      if [[ "$host_arch" != "x86_64" ]]; then
        echo "ERROR: ARCH=amd64 需要 x86_64 构建宿主（当前 $host_arch），AppImage 工具链无法交叉" >&2
        exit 1
      fi
      ;;
    arm64)
      if [[ "$host_arch" != "aarch64" ]]; then
        echo "ERROR: ARCH=arm64 需要 aarch64 构建宿主（当前 $host_arch），AppImage 工具链无法交叉" >&2
        exit 1
      fi
      ;;
    linux) : ;;  # 宿主自动
  esac
  echo "==> 构建 linux AppImage (arch=$want_arch) ..."
  bash "$REPO_ROOT/docker/pqt/build-pqt.sh" --project pqt_memory_edit --linux --version "$VERSION" --output "$OUTPUT_DIR"
  # linux_release.sh 已把 AppImage 生成到 OUTPUT_DIR（WORK_DIR），不存在则从源码树回退拷贝
  local app="$(find "$OUTPUT_DIR" -maxdepth 1 -name 'qt_mem_edit_*.AppImage' | head -1)"
  if [ -z "$app" ]; then app="$(find "$SCRIPT_DIR" -maxdepth 1 -name 'qt_mem_edit_*.AppImage' | head -1)"; fi
  if [ -z "$app" ]; then echo "ERROR: 未找到 AppImage 产物" >&2; exit 1; fi
  local appname
  appname="$(basename "$app")"
  if [ ! -f "$OUTPUT_DIR/$appname" ]; then cp "$app" "$OUTPUT_DIR/"; fi
  file "$app" | head -1
}

build_windows() {
  echo "==> windows exe 交叉编译 ..."
  bash "$REPO_ROOT/docker/pqt/build-pqt.sh" --project pqt_memory_edit --windows --version "$VERSION" --output "$OUTPUT_DIR"
  local exe
  exe="$(find "$OUTPUT_DIR" "$SCRIPT_DIR" -maxdepth 3 -name 'qt_mem_edit_*.exe' 2>/dev/null | grep -v 'libs/' | head -1)"
  exe="${exe:-$(find "$OUTPUT_DIR" "$SCRIPT_DIR" -maxdepth 3 -name '*.exe' 2>/dev/null | grep -v 'libs/' | head -1)}"
  if [ -n "$exe" ]; then
    # build-pqt.sh 已把 exe 收拢到 OUTPUT_DIR 根；仅当不在 OUTPUT_DIR 时才拷贝（避免 cp: same file）
    local out_dir="${OUTPUT_DIR%/}"
    if [ "$exe" != "$out_dir/$(basename "$exe")" ]; then
      cp "$exe" "$out_dir/"
    fi
    file "$exe" | head -1
  else
    echo "ERROR: 未找到 windows exe 产物" >&2
    exit 1
  fi
}

case "$ARCH" in
  amd64|arm64|linux) build_linux "$ARCH" ;;
  windows|win) build_windows ;;
  all) build_linux amd64; build_windows ;;
  *) echo "ERROR: ARCH 必须是 amd64|arm64|windows|all" >&2; exit 1 ;;
esac

echo "==> pqt_memory_edit 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
