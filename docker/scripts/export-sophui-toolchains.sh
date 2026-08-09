#!/usr/bin/env bash
# 从 13.24 服务器的 cross_build_sophon_u20:v1 镜像导出 pSophUI 交叉 Qt 库
# （aarch64 Qt 5.12.8；不含 Linaro GCC —— 编译改用系统 apt aarch64-linux-gnu-gcc）。
#
# 用法:
#   bash docker/scripts/export-sophui-toolchains.sh [--image <name>] [--out <dir>]
#     --image  源镜像名（默认 cross_build_sophon_u20:v1）
#     --out    导出目录（默认 docker/toolchains/）
#
# 导出为 .tar.zst 后，`bash docker/build.sh --with-sophui-toolchain` 会将其内置于镜像；
# 内置后构建期不再依赖独立镜像（与 M2 处理 dfss 工具链的方式一致）。
# 若导出目录已存在同名归档，直接复用，不重复导出。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DOCKER_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${IMAGE:-cross_build_sophon_u20:v1}"
OUT_DIR="${OUT_DIR:-${DOCKER_DIR}/toolchains}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "${OUT_DIR}"

# 容器内 Qt 库路径（cross_build_sophon_u20:v1 同款，绝对引用硬编码 /env）
QT_SRC="/env/qt_5.12.8_nosysroot"

ARCHIVE="${OUT_DIR}/sophui-cross-toolchains.tar.zst"

if [[ -f "${ARCHIVE}" ]]; then
  echo "已存在: ${ARCHIVE}（跳过）"
  exit 0
fi

if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "错误: 找不到源镜像 '${IMAGE}'。" >&2
  echo "请在 13.24 服务器确认该镜像存在: docker images | grep cross_build_sophon_u20" >&2
  exit 1
fi

if ! docker run --rm "${IMAGE}" sh -c "test -d '${QT_SRC}'" >/dev/null 2>&1; then
  echo "错误: 镜像 '${IMAGE}' 中未找到 ${QT_SRC}。" >&2
  exit 1
fi

echo "导出 ${QT_SRC} -> ${ARCHIVE}（剔除 examples/qml 冗余）..."
# 镜像内无 zstd, 直接流式导到宿主用 zstd 压缩; 剔除编译 pSophUI 不需要的 examples/qml
docker run --rm "${IMAGE}" sh -c "rm -rf '${QT_SRC}/examples' '${QT_SRC}/qml'; tar -C /env -cf - qt_5.12.8_nosysroot" \
  | zstd -q -T0 -o "${ARCHIVE}"
ls -lh "${ARCHIVE}"

echo "完成。构建镜像时加 --with-sophui-toolchain 自动内置，或在 Dockerfile 构建上下文放 toolchains/ 目录。"
