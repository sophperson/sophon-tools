#!/usr/bin/env bash
# sophon-tools-build 镜像构建脚本（一条命令构建）
#
# 用法:
#   bash docker/build.sh                 # 基础镜像(不含 dfss 私有工具链)
#   bash docker/build.sh --with-dfss-toolchains   # 内置 sw_64/loongarch64 私有工具链
#   bash docker/build.sh --tag mytag --no-cache
#
# 依赖: docker(≥20.10, BuildKit 默认开启), 网络可访问 go.dev/nodejs.org/musl.cc
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 默认镜像名 + 标签
IMAGE_NAME="${IMAGE_NAME:-sophon-tools-build}"
TAG=""
WITH_DFSS=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-dfss-toolchains) WITH_DFSS=1; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --no-cache) EXTRA_ARGS+=(--no-cache); shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${TAG}" ]] || TAG="latest"

# 版本源: docker/versions.env(唯一版本锁定点)
# shellcheck disable=SC1091
source "${DOCKER_DIR}/versions.env"

# 校验基础镜像 digest 可拉取
BASE_IMG="${UBUNTU_BASE_DIGEST}"
echo "==> 基础镜像: ${BASE_IMG}"
docker pull "${BASE_IMG}" >/dev/null 2>&1 || { echo "无法拉取基础镜像, 检查网络" >&2; exit 1; }

# dfss 私有工具链: 检查 toolchains/ 目录
BUILD_CONTEXT="${DOCKER_DIR}"
if [[ "${WITH_DFSS}" = "1" ]]; then
  TOOLCHAIN_DIR="${DOCKER_DIR}/toolchains"
  if [[ ! -f "${TOOLCHAIN_DIR}/swgcc830_cross_tools.tar.zst" ]] \
     && [[ ! -f "${TOOLCHAIN_DIR}/loongarch64-cross-tools.tar.zst" ]]; then
    echo "==> toolchains/ 为空, 先从 13.24 容器导出(需要 docker 容器 bm1684_zzt 或 cross_build_sophon_u20:v1)..." >&2
    bash "${DOCKER_DIR}/scripts/export-dfss-toolchains.sh" --out "${TOOLCHAIN_DIR}"
  fi
  EXTRA_ARGS+=(--build-arg WITH_DFSS=1)
fi

echo "==> 构建上下文: ${BUILD_CONTEXT}"
echo "==> 版本: Go ${GO_VERSION} / Rust ${RUST_VERSION} / Node ${NODE_VERSION} / pnpm ${PNPM_VERSION}"
[[ "${WITH_DFSS}" = "1" ]] && echo "==> 内置 dfss 私有工具链(sw_64 + loongarch64)"

docker build \
  --build-arg UBUNTU_BASE_DIGEST="${UBUNTU_BASE_DIGEST}" \
  --build-arg GO_VERSION="${GO_VERSION}" \
  --build-arg GO_TARBALL_URL="${GO_TARBALL_URL}" \
  --build-arg GO_TARBALL_SHA256="${GO_TARBALL_SHA256}" \
  --build-arg RUST_VERSION="${RUST_VERSION}" \
  --build-arg NODE_TARBALL_URL="${NODE_TARBALL_URL}" \
  --build-arg NODE_TARBALL_SHA256="${NODE_TARBALL_SHA256}" \
  --build-arg PNPM_VERSION="${PNPM_VERSION}" \
  --build-arg YARN_VERSION="${YARN_VERSION}" \
  "${EXTRA_ARGS[@]}" \
  -f "${DOCKER_DIR}/Dockerfile" \
  -t "${IMAGE_NAME}:${TAG}" \
  "${BUILD_CONTEXT}"

echo "==> 构建完成: ${IMAGE_NAME}:${TAG}"
echo "==> 自检: bash docker/verify.sh --image ${IMAGE_NAME}:${TAG}"
