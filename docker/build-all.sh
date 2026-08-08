#!/usr/bin/env bash
# sophon-tools-build 统一构建全部 17 子项目（镜像内一键编译）
#
# 目标: 在 sophon-tools-build 镜像内预装工具链, 对全部子项目执行所有平台的编译。
# 本脚本是统一入口, 按 M1 规范驱动每个子项目的 release.sh（统一接口）。
#
# 统一接口 (M1 规范 v0.1):
#   bash release.sh [ARCH] [VERSION]
#     ARCH:    arm64 | amd64 | all（默认按子项目）
#     VERSION: 显式版本号（缺省用子项目版本来源）
#     env OUTPUT_DIR: 覆盖产物目录（默认 <repo>/output/<子项目>/）
#
# 用法:
#   bash docker/build-all.sh                    # 构建全部 17 子项目(默认平台)
#   bash docker/build-all.sh --project pbmssm   # 只构建指定子项目
#   bash docker/build-all.sh --arch arm64       # 只构建指定架构
#   bash docker/build-all.sh --image sophon-tools-build:m2
#   bash docker/build-all.sh --list             # 列出子项目与平台
#
# 产物: 全部汇聚到仓库根 output/<子项目>/ (与根 release.sh 一致)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DOCKER_DIR="${SCRIPT_DIR}"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${IMAGE:-sophon-tools-build:m2}"
ONLY_PROJECT=""
ONLY_ARCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) ONLY_PROJECT="$2"; shift 2; continue ;;
    --arch) ONLY_ARCH="$2"; shift 2; continue ;;
    --image) IMAGE="$2"; shift 2; continue ;;
    --list) LIST_ONLY=1 ;;
    -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | head -30; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

# 子项目 -> 默认平台 (release.sh 的第一参数 ARCH)
declare -A DEFAULT_ARCH
DEFAULT_ARCH[pbmssm]=arm64
DEFAULT_ARCH[psophliteos]=arm64
DEFAULT_ARCH[pbmsec]=all
DEFAULT_ARCH[psocbak]=arm64
DEFAULT_ARCH[pget_info]=amd64
DEFAULT_ARCH[pmem_aging_test]=arm64
DEFAULT_ARCH[pmemory_edit]=arm64
DEFAULT_ARCH[pota_update]=arm64
DEFAULT_ARCH[pautotelecomm]=arm64
DEFAULT_ARCH[pbm_set_ip]=arm64
DEFAULT_ARCH[pdfss_cpp]=host
DEFAULT_ARCH[pqt_batch_deployment]=amd64
DEFAULT_ARCH[pqt_memory_edit]=amd64
DEFAULT_ARCH[pSophUI]=arm64
DEFAULT_ARCH[pmulti_video_qt]=arm64
DEFAULT_ARCH[psoph_phytool]=all
DEFAULT_ARCH[pspacc_efuse_demo]=amd64

# 子项目 -> 平台说明 (M1 盘点)
declare -A PLATFORMS
PLATFORMS[pbmssm]="arm64(musl静态)/amd64"
PLATFORMS[psophliteos]="arm64(musl静态)/amd64"
PLATFORMS[pbmsec]="all(deb含双架构)"
PLATFORMS[psocbak]="arm64"
PLATFORMS[pget_info]="arm64/amd64"
PLATFORMS[pmem_aging_test]="arm64"
PLATFORMS[pmemory_edit]="arm64"
PLATFORMS[pota_update]="arm64"
PLATFORMS[pautotelecomm]="arm64"
PLATFORMS[pbm_set_ip]="arm64(musl静态)/amd64"
PLATFORMS[pdfss_cpp]="amd64/arm64/armbi/loongarch64/riscv64/sw_64/win-amd64/win-i686"
PLATFORMS[pqt_batch_deployment]="amd64/arm64"
PLATFORMS[pqt_memory_edit]="amd64/arm64 + windows"
PLATFORMS[pSophUI]="arm64(交叉Qt)"
PLATFORMS[pmulti_video_qt]="arm64(需SDK)"
PLATFORMS[psoph_phytool]="通用脚本"
PLATFORMS[pspacc_efuse_demo]="amd64/arm64"

# 子项目 -> 专用镜像覆盖（默认用统一镜像 sophon-tools-build）
#   pqt 系列: linux AppImage 需 glibc<=2.31 -> pqt 专用 20.04 镜像
#   pSophUI: 需 aarch64 Qt 交叉工具链 -> cross_build_sophon_u20 (13.24 同款)
declare -A IMAGE_OVERRIDES
IMAGE_OVERRIDES[pqt_batch_deployment]="${PQT_IMAGE:-sophon-tools-build-pqt:latest}"
IMAGE_OVERRIDES[pqt_memory_edit]="${PQT_IMAGE:-sophon-tools-build-pqt:latest}"
IMAGE_OVERRIDES[pSophUI]="${CROSS_QT_IMAGE:-cross_build_sophon_u20:v1}"

# 宿主执行项目（不在容器内跑 release.sh）：
#   pqt 系列 release.sh 内部调用 docker/pqt/build-pqt.sh，后者用 docker 起 pqt 专用容器，
#   因此必须在宿主（有 docker）直接执行 release.sh，而非在容器内嵌套 docker。
declare -A HOST_RUN
HOST_RUN[pqt_batch_deployment]=1
HOST_RUN[pqt_memory_edit]=1

# 子项目 -> 额外环境 (镜像内 export; 以 ; 分隔)
declare -A EXTRA_ENV
EXTRA_ENV[pbm_set_ip]="export PATH=\${HOME}/.cargo/bin:/opt/cargo/bin:\$PATH"
EXTRA_ENV[psophliteos]="export PATH=/opt/nodejs/bin:/opt/go/bin:\$PATH"
EXTRA_ENV[pbmssm]="export PATH=/opt/go/bin:\$PATH"
EXTRA_ENV[pdfss_cpp]="export PATH=/env/loongson-gnu-toolchain-8.3-x86_64-loongarch64-linux-gnu-rc1.1/bin:/usr/sw/swgcc830_cross_tools/usr/bin:\$PATH"
EXTRA_ENV[pSophUI]="export PATH=/env/qt_5.12.8_nosysroot/bin:/env/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu/bin:\$PATH; export QMAKESPEC=/env/qt_5.12.8_nosysroot/mkspecs/linux-aarch64-gnu-g++"

if [[ "${LIST_ONLY:-0}" = "1" ]]; then
  echo "=== sophon-tools 17 子项目构建清单 ==="
  for p in $(echo "${!DEFAULT_ARCH[@]}" | tr ' ' '\n' | sort); do
    img="${IMAGE_OVERRIDES[$p]:-$IMAGE}"
    printf "  %-22s 平台: %-40s 镜像: %s\n" "$p" "${PLATFORMS[$p]}" "$img"
  done
  exit 0
fi

# 输出目录
mkdir -p "${REPO_ROOT}/output"
echo "==> 统一构建, 输出: ${REPO_ROOT}/output"

run_one() {
  local p="$1"
  local arch="${ONLY_ARCH:-${DEFAULT_ARCH[$p]}}"
  local img="${IMAGE_OVERRIDES[$p]:-$IMAGE}"
  echo ""
  echo "========== [${p}] 平台: ${PLATFORMS[$p]} arch=${arch} 镜像: ${img} =========="
  local src_dir="${REPO_ROOT}/source/${p}"
  [[ -d "${src_dir}" ]] || { echo "  [SKIP] 目录不存在: ${src_dir}"; return 0; }

  # pqt 系列在宿主直接执行 release.sh（内部需要 docker 起专用容器）
  if [[ "${HOST_RUN[$p]:-0}" = "1" ]]; then
    (
      cd "${src_dir}"
      echo "  >> (宿主) bash release.sh ${arch}"
      OUTPUT_DIR="${REPO_ROOT}/output/${p}" bash release.sh "${arch}" 2>&1 | tail -20
    ) | sed 's/^/    /'
    local rc=${PIPESTATUS[0]}
    echo "  [${p}] 退出码: ${rc}"
    return 0
  fi

  local extra_env="${EXTRA_ENV[$p]:-}"
  docker run --rm --privileged \
    -v /dev:/dev \
    -v "${REPO_ROOT}":/workspace/sophon-tools \
    -w "/workspace/sophon-tools/source/${p}" \
    -e OUTPUT_DIR="/workspace/sophon-tools/output/${p}" \
    "${img}" bash -c "
      set -e
      git config --global --add safe.directory '*' 2>/dev/null || true
      git config --global --add safe.directory /workspace/sophon-tools 2>/dev/null || true
      ${extra_env}
      echo '  >> bash release.sh ${arch}'
      bash release.sh ${arch} 2>&1 | tail -20
    " 2>&1 | sed 's/^/    /'
  local rc=${PIPESTATUS[0]}
  echo "  [${p}] 退出码: ${rc}"
}

if [[ -n "${ONLY_PROJECT}" ]]; then
  run_one "${ONLY_PROJECT}"
else
  for p in $(echo "${!DEFAULT_ARCH[@]}" | tr ' ' '\n' | sort); do
    run_one "$p"
  done
fi

echo ""
echo "==> 统一构建完成, 产物在 ${REPO_ROOT}/output/"
echo "==> 汇总: bash docker/verify.sh --image ${IMAGE}"
