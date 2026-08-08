#!/usr/bin/env bash
# pqt 系列(Qt GUI 工具)一键编译脚本 —— linux AppImage / windows exe
#
# 支持子项目: pqt_memory_edit(图形化远程内存修改工具), pqt_batch_deployment(批量部署工具)
#
# 用法:
#   bash docker/pqt/build-pqt.sh --project pqt_memory_edit --linux       # linux AppImage
#   bash docker/pqt/build-pqt.sh --project pqt_memory_edit --windows     # windows exe (需 Qt mingw)
#   bash docker/pqt/build-pqt.sh --project pqt_memory_edit --all         # 两端
#   bash docker/pqt/build-pqt.sh --project pqt_batch_deployment --linux
#
# 依赖: docker, sophon-tools-build-pqt 镜像(linux端); mingw Qt(交叉编译) 见下
#
# 关键前置(linux): pqt_memory_edit 的 resources.qrc 引用 memory_edit.tar.xz,
#   该文件由 source/pmemory_edit/release.sh 生成; 构建前自动生成并复制。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PQT_IMAGE="${PQT_IMAGE:-sophon-tools-build-pqt:latest}"
PROJECT="pqt_memory_edit"
MODE=""  # linux / windows / all

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2; continue ;;
    --linux) MODE="linux" ;;
    --windows) MODE="windows" ;;
    --all) MODE="all" ;;
    --image) PQT_IMAGE="$2"; shift 2; continue ;;
    -h|--help)
      grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
      exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

[[ -n "${MODE}" ]] || { echo "请指定 --linux 或 --windows 或 --all" >&2; exit 1; }
SRC_DIR="${REPO_ROOT}/source/${PROJECT}"
[[ -d "${SRC_DIR}" ]] || { echo "未找到子项目: ${SRC_DIR}" >&2; exit 1; }

# ---- 准备 memory_edit.tar.xz (pqt_memory_edit 专用) ----
prepare_memory_edit_tarxz() {
  if [[ "${PROJECT}" != "pqt_memory_edit" ]]; then return 0; fi
  local src="${SRC_DIR}/memory_edit.tar.xz"
  if [[ -f "${src}" ]]; then
    echo "==> 已有 memory_edit.tar.xz, 复用"
    return 0
  fi
  echo "==> 生成 memory_edit.tar.xz (来自 pmemory_edit)..."
  local pmem="${REPO_ROOT}/source/pmemory_edit"
  (cd "${pmem}" && bash release.sh >/dev/null 2>&1)
  local tarxz
  tarxz="$(find "${pmem}/output" -name 'memory_edit_*.tar.xz' 2>/dev/null | head -1)"
  if [[ -z "${tarxz}" ]]; then
    echo "错误: pmemory_edit 未产出 memory_edit tar.xz" >&2
    exit 1
  fi
  cp "${tarxz}" "${src}"
  echo "==> 已复制: ${src}"
}

# ---- linux 端: AppImage ----
build_linux() {
  prepare_memory_edit_tarxz
  echo "==> 构建 ${PROJECT} linux AppImage (镜像 ${PQT_IMAGE})..."
  # 确保镜像存在
  docker image inspect "${PQT_IMAGE}" >/dev/null 2>&1 || {
    echo "==> 构建 pqt 基础镜像..." >&2
    docker build -f "${DOCKER_DIR}/pqt/Dockerfile" -t "${PQT_IMAGE}" "${DOCKER_DIR}/pqt" >&2
  }
  docker run --rm --privileged \
    -v /dev:/dev \
    -v "${SRC_DIR}":/root/workspace \
    -w /root/workspace \
    "${PQT_IMAGE}" /bin/bash -c "
      git config --global --add safe.directory /root/workspace
      bash linux_release.sh
    " 2>&1 | tail -20
  echo "==> linux AppImage 完成"
}

# ---- windows 端: exe (需 Qt mingw 交叉编译环境) ----
build_windows() {
  echo "==> windows 端交叉编译..."
  # 注意: windows 构建需要 sophon-tools-build(含 mingw g++), 非 pqt 镜像
  local image="${IMAGE:-sophon-tools-build:m2}"
  local qt_prefix="${QT_PREFIX:-/opt/qt-mingw}"
  # 确保 Qt mingw 静态库存在
  if [[ ! -f "${qt_prefix}/lib/libQt5Widgets.a" ]]; then
    echo "==> 未找到 Qt mingw 静态库 (${qt_prefix}), 先交叉编译 Qt (约 20-40 分钟)..."
    PREFIX="${qt_prefix}" bash "${DOCKER_DIR}/pqt/build-qt-mingw.sh" || {
      echo "Qt mingw 编译失败" >&2; exit 1
    }
  fi
  # 内存修改工具前置依赖
  prepare_memory_edit_tarxz
  docker run --rm \
    -v "${SRC_DIR}":/workspace/src \
    -v "${qt_prefix}":/opt/qt-mingw \
    -w /workspace/src \
    "${image}" bash -c '
      set -e
      export DEBIAN_FRONTEND=noninteractive
      if ! command -v x86_64-w64-mingw32-g++-posix >/dev/null; then
        apt-get update -qq
        apt-get install -y --no-install-recommends g++-mingw-w64-x86-64 >/dev/null 2>&1
      fi
      # posix 线程模型 (Qt 静态库需要 std::mutex)
      mkdir -p /opt/mingw-posix/bin
      for t in gcc g++ cpp cc c++ gcc-ar gcc-nm gcc-ranlib; do
        [ -x /usr/bin/x86_64-w64-mingw32-${t}-posix ] && ln -sf /usr/bin/x86_64-w64-mingw32-${t}-posix /opt/mingw-posix/bin/x86_64-w64-mingw32-${t}
      done
      export PATH=/opt/mingw-posix/bin:$PATH
      # 大写 mingw 头文件符号链接 (代码 include <Winsock2.h>)
      mkdir -p /tmp/mingw-inc
      ln -sf /usr/x86_64-w64-mingw32/include/winsock2.h /tmp/mingw-inc/Winsock2.h
      # WS2_32 库大小写兼容
      ln -sf /usr/x86_64-w64-mingw32/lib/libws2_32.a /usr/x86_64-w64-mingw32/lib/libWS2_32.a
      # mingw toolchain
      cat > /tmp/tc.cmake <<TOOL
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_FIND_ROOT_PATH /opt/qt-mingw /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TOOL
      cd /workspace/src
      rm -rf build-win
      mkdir build-win && cd build-win
      export QT_PLATFORM_DIR=/opt/qt-mingw
      export QT_GCC_PLATFORM_DIR=/opt/mingw-posix/bin
      cmake .. -DCMAKE_TOOLCHAIN_FILE=/tmp/tc.cmake -DCMAKE_BUILD_TYPE=Release \
        "-DCMAKE_CXX_FLAGS=-I/tmp/mingw-inc" "-DCMAKE_C_FLAGS=-I/tmp/mingw-inc"
      make -j$(nproc)
      echo "==> windows exe 产物:"
      ls -la qt_mem_edit*.exe 2>/dev/null || ls -la *.exe
    '
}

case "${MODE}" in
  linux) build_linux ;;
  windows) build_windows ;;
  all) build_linux; build_windows ;;
esac
