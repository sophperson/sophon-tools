#!/bin/bash
# pqt_memory_edit 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    amd64 | arm64 | all | windows（默认 amd64；linux AppImage 宿主架构）
#   VERSION: 显式版本号（默认从 CMakeLists MY_PROJECT_VERSION 解析）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pqt_memory_edit/）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-amd64}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pqt_memory_edit}"

VERSION="${2:-$(grep -E '^set\(MY_PROJECT_VERSION "[^"]+"\)' "$SCRIPT_DIR/CMakeLists.txt" | grep -o -E '[0-9]+\.[0-9]+\.[0-9]+')}"
echo "==> pqt_memory_edit version=$VERSION arch=$ARCH"

mkdir -p "$OUTPUT_DIR"

build_linux() {
  echo "==> 构建 linux AppImage ..."
  bash "$REPO_ROOT/docker/pqt/build-pqt.sh" --project pqt_memory_edit --linux
  local app="$(find "$SCRIPT_DIR" -maxdepth 1 -name 'qt_mem_edit_*.AppImage' | head -1)"
  if [ -z "$app" ]; then app="$(find "$SCRIPT_DIR" -maxdepth 1 -name '*.AppImage' | head -1)"; fi
  if [ -z "$app" ]; then echo "ERROR: 未找到 AppImage 产物" >&2; exit 1; fi
  cp "$app" "$OUTPUT_DIR/"
  file "$app" | head -1
}

build_windows() {
  echo "==> windows exe 交叉编译 ..."
  bash "$REPO_ROOT/docker/pqt/build-pqt.sh" --project pqt_memory_edit --windows
  local exe
  exe="$(find "$SCRIPT_DIR" -maxdepth 2 -name 'qt_mem_edit.exe' 2>/dev/null | head -1)"
  exe="${exe:-$(find "$SCRIPT_DIR" -maxdepth 2 -name '*.exe' 2>/dev/null | grep -v 'libs/' | head -1)}"
  if [ -n "$exe" ]; then
    cp "$exe" "$OUTPUT_DIR/"
    file "$exe" | head -1
  else
    echo "WARN: 未找到 windows exe 产物" >&2
  fi
}

case "$ARCH" in
  amd64|arm64|linux) build_linux ;;
  windows|win) build_windows ;;
  all) build_linux; build_windows ;;
  *) echo "ERROR: ARCH 必须是 amd64|arm64|windows|all" >&2; exit 1 ;;
esac

echo "==> pqt_memory_edit 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
