#!/usr/bin/env bash
# sophon-tools-build 镜像构建脚本（一条命令构建，M5 单镜像合并）
#
# 用法:
#   bash docker/build.sh                 # 基础镜像(不含 dfss/qt-mingw/pSophUI 私有工具链)
#   bash docker/build.sh --with-dfss-toolchains   # 内置 sw_64/loongarch64 私有工具链
#   bash docker/build.sh --with-qt-mingw          # 内置 Qt mingw 静态库(pqt windows)
#   bash docker/build.sh --with-sophui-toolchain  # 内置 pSophUI aarch64 Qt 交叉工具链
#   bash docker/build.sh --tag mytag --no-cache
#
# 依赖: docker(≥20.10, BuildKit 默认开启), 网络可访问 go.dev/nodejs.org/musl.cc。
#       pSophUI 工具链(及 dfss)以 toolchains/ 归档内置, 不依赖 cross_build_sophon_u20:v1 独立镜像。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 默认镜像名 + 标签
IMAGE_NAME="${IMAGE_NAME:-sophon-tools-build}"
TAG=""
WITH_DFSS=0
WITH_QT_MINGW=0
WITH_SOPHUI=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-dfss-toolchains) WITH_DFSS=1; shift ;;
    --with-qt-mingw) WITH_QT_MINGW=1; shift ;;
    --with-sophui-toolchain) WITH_SOPHUI=1; shift ;;
    --tag) TAG="$2"; shift 2 ;;
    --no-cache) EXTRA_ARGS+=(--no-cache); shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${TAG}" ]] || TAG="unified"

# 版本源: docker/versions.env(唯一版本锁定点)
# shellcheck disable=SC1091
source "${DOCKER_DIR}/versions.env"

# 校验基础镜像 digest 可拉取
BASE_IMG="${UBUNTU_BASE_DIGEST}"
echo "==> 基础镜像: ${BASE_IMG}"
docker pull "${BASE_IMG}" >/dev/null 2>&1 || { echo "无法拉取基础镜像, 检查网络" >&2; exit 1; }

# dfss 私有工具链: 检查 toolchains/ 目录
BUILD_CONTEXT="${DOCKER_DIR}"
TOOLCHAIN_DIR="${DOCKER_DIR}/toolchains"
mkdir -p "${TOOLCHAIN_DIR}"   # Dockerfile 无条件 COPY toolchains/, 目录必须存在(可为空)
if [[ "${WITH_DFSS}" = "1" ]]; then
  if [[ ! -f "${TOOLCHAIN_DIR}/swgcc830_cross_tools.tar.zst" ]] \
     && [[ ! -f "${TOOLCHAIN_DIR}/loongarch64-cross-tools.tar.zst" ]]; then
    echo "==> toolchains/ 为空, 先从 13.24 容器导出(需要 docker 容器 bm1684_zzt 或 cross_build_sophon_u20:v1)..." >&2
    bash "${DOCKER_DIR}/scripts/export-dfss-toolchains.sh" --out "${TOOLCHAIN_DIR}"
  fi
  EXTRA_ARGS+=(--build-arg WITH_DFSS=1)
fi

# pSophUI 交叉工具链(aarch64 Qt 5.12.8 + Linaro GCC 6.3): 检查 toolchains/ 归档
# 来源优先 13.24 cross_build_sophon_u20:v1 镜像内容导出(参考 M2 处理 dfss 工具链的方式),
# 以归档内置后, 构建期不再依赖独立镜像。
SOPHUI_ARCHIVE="${TOOLCHAIN_DIR}/${SOPHUI_ARCHIVE:-sophui-cross-toolchains.tar.zst}"
if [[ "${WITH_SOPHUI}" = "1" ]]; then
  if [[ ! -f "${SOPHUI_ARCHIVE}" ]]; then
    echo "==> sophui-cross-toolchains.tar.zst 不存在, 先从 13.24 cross_build_sophon_u20:v1 导出..." >&2
    bash "${DOCKER_DIR}/scripts/export-sophui-toolchains.sh" --out "${TOOLCHAIN_DIR}"
  fi
  EXTRA_ARGS+=(--build-arg WITH_SOPHUI=1)
fi

# Qt mingw 静态库(pqt windows exe): 检查 toolchains/qt-mingw
# 注意: 必须在 20.04 基座内从源码交叉编译——宿主机 /opt/qt-mingw 若是 22.04 编译的,
#       其宿主工具(uic/moc 等)依赖 glibc 2.33+, 在 20.04 镜像内无法运行。
#       故这里一律走 build-qt-mingw.sh 从源码构建, 不复用宿主现成目录。
if [[ "${WITH_QT_MINGW}" = "1" ]]; then
  if [[ ! -f "${TOOLCHAIN_DIR}/qt-mingw.tar.zst" ]]; then
    if [[ ! -d /opt/qt-mingw ]] || [[ ! -f /opt/qt-mingw/lib/libQt5Widgets.a ]]; then
      echo "==> toolchains/qt-mingw 不存在, 开始交叉编译 Qt (约 20-40 分钟)..." >&2
      PREFIX=/opt/qt-mingw bash "${DOCKER_DIR}/pqt/build-qt-mingw.sh"
    else
      echo "==> 复用 /opt/qt-mingw 已编译产物, 校验宿主工具与 20.04 基座兼容..." >&2
      if docker run --rm -v /opt/qt-mingw:/opt/qt-mingw:ro "${IMAGE_NAME}:unified" bash -c '/opt/qt-mingw/bin/uic --version' >/dev/null 2>&1; then
        echo "==> /opt/qt-mingw 与 20.04 基座兼容, 直接复用" >&2
      else
        echo "==> /opt/qt-mingw 宿主工具依赖过高 glibc(22.04 编译), 重新从源码编译..." >&2
        sudo rm -rf /opt/qt-mingw 2>/dev/null || rm -rf /opt/qt-mingw
        PREFIX=/opt/qt-mingw bash "${DOCKER_DIR}/pqt/build-qt-mingw.sh"
      fi
    fi
    tar -C /opt/qt-mingw -cf - . | zstd -q -T0 > "${TOOLCHAIN_DIR}/qt-mingw.tar.zst"
  fi
  EXTRA_ARGS+=(--build-arg WITH_QT_MINGW=1)
fi

echo "==> 构建上下文: ${BUILD_CONTEXT}"
echo "==> 版本: Go ${GO_VERSION} / Rust ${RUST_VERSION} / Node ${NODE_VERSION} / pnpm ${PNPM_VERSION}"
[[ "${WITH_DFSS}" = "1" ]] && echo "==> 内置 dfss 私有工具链(sw_64 + loongarch64)"
[[ "${WITH_QT_MINGW}" = "1" ]] && echo "==> 内置 Qt mingw 静态库(pqt windows)"
[[ "${WITH_SOPHUI}" = "1" ]] && echo "==> 内置 pSophUI 交叉工具链(aarch64 Qt 5.12.8 + Linaro GCC 6.3)"

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
