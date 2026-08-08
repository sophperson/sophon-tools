#!/usr/bin/env bash
# sophon-tools-build 统一构建全部 17 子项目（镜像内一键编译）
#
# 目标: 在 sophon-tools-build 镜像内预装工具链, 对全部子项目执行所有平台的编译。
# 本脚本是统一入口, 按 M1 规范驱动每个子项目的构建脚本。
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
    -h|--help) grep -E '^#' "$0" | sed 's/^# \{0,1\}//' | head -25; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

# 子项目 -> 构建脚本/命令 (镜像内相对 source/<项目>/ 执行)
declare -A PROJECTS
PROJECTS[pbmssm]="bash build/build-deb-bmssm.sh 2.1.0 ${ONLY_ARCH:-arm64}"
PROJECTS[psophliteos]="cd frontend && rm -rf node_modules && CI=true pnpm install --no-frozen-lockfile 2>/dev/null; cd .. && bash build/build-deb-sophliteos.sh 2.1.0 soc"
PROJECTS[pbmsec]="bash release.sh"
PROJECTS[psocbak]="bash release.sh"
PROJECTS[pget_info]="bash release.sh"
PROJECTS[pmem_aging_test]="bash release.sh"
PROJECTS[pmemory_edit]="bash release.sh"
PROJECTS[pota_update]="bash release.sh"
PROJECTS[pautotelecomm]="bash release.sh"
PROJECTS[pbm_set_ip]="cd bm_set_ip && cargo build --target aarch64-unknown-linux-musl --release"
PROJECTS[pdfss_cpp]="bash linux_release.sh ${ONLY_ARCH:-host}"
PROJECTS[pqt_batch_deployment]="bash docker/pqt/build-pqt.sh --project pqt_batch_deployment --linux"
PROJECTS[pqt_memory_edit]="bash docker/pqt/build-pqt.sh --project pqt_memory_edit --linux"
PROJECTS[pSophUI]="echo 'SKIP: 需交叉 Qt 环境(M3)'"
PROJECTS[pmulti_video_qt]="echo 'SKIP: 需 libsophon SDK(M3)'"
PROJECTS[psoph_phytool]="cp sophon_phytool.sh output/"
PROJECTS[pspacc_efuse_demo]="gcc -o output/spacc_efuse_demo spacc_efuse_demo.c"

# 平台说明 (M1 盘点)
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
PLATFORMS[pbm_set_ip]="arm64(musl静态)"
PLATFORMS[pdfss_cpp]="amd64/arm64/armbi/loongarch64/riscv64/sw_64/win-amd64/win-i686"
PLATFORMS[pqt_batch_deployment]="amd64/arm64"
PLATFORMS[pqt_memory_edit]="amd64/arm64 + windows"
PLATFORMS[pSophUI]="arm64(需交叉Qt)"
PLATFORMS[pmulti_video_qt]="arm64(需SDK)"
PLATFORMS[psoph_phytool]="通用脚本"
PLATFORMS[pspacc_efuse_demo]="amd64/arm64"

if [[ "${LIST_ONLY:-0}" = "1" ]]; then
  echo "=== sophon-tools 17 子项目构建清单 (镜像 ${IMAGE}) ==="
  for p in $(echo "${!PROJECTS[@]}" | tr ' ' '\n' | sort); do
    printf "  %-22s 平台: %s\n" "$p" "${PLATFORMS[$p]}"
  done
  exit 0
fi

# 输出目录
mkdir -p "${REPO_ROOT}/output"
echo "==> 统一构建 (镜像 ${IMAGE}), 输出: ${REPO_ROOT}/output"

run_one() {
  local p="$1"
  echo ""
  echo "========== [${p}] 平台: ${PLATFORMS[$p]} =========="
  local src_dir="${REPO_ROOT}/source/${p}"
  [[ -d "${src_dir}" ]] || { echo "  [SKIP] 目录不存在: ${src_dir}"; return 0; }
  mkdir -p "${src_dir}/output"
  local cmd="${PROJECTS[$p]}"
  docker run --rm --privileged \
    -v /dev:/dev \
    -v "${REPO_ROOT}":/workspace/sophon-tools \
    -w "/workspace/sophon-tools/source/${p}" \
    "${IMAGE}" bash -c "
      set -e
      git config --global --add safe.directory '*' 2>/dev/null || true
      git config --global --add safe.directory /workspace/sophon-tools 2>/dev/null || true
      export PATH=\"/env/loongson-gnu-toolchain-8.3-x86_64-loongarch64-linux-gnu-rc1.1/bin:/usr/sw/swgcc830_cross_tools/usr/bin:\$PATH\"
      mkdir -p output
      echo '  >> ${cmd}'
      ${cmd} 2>&1 | tail -15
    " 2>&1 | sed 's/^/    /'
  local rc=${PIPESTATUS[0]}
  echo "  [${p}] 退出码: ${rc}"
}

if [[ -n "${ONLY_PROJECT}" ]]; then
  run_one "${ONLY_PROJECT}"
else
  for p in $(echo "${!PROJECTS[@]}" | tr ' ' '\n' | sort); do
    run_one "$p"
  done
fi

echo ""
echo "==> 统一构建完成, 产物在 ${REPO_ROOT}/output/"
echo "==> 汇总: bash docker/verify.sh --image ${IMAGE}"
