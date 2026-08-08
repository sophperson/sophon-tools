#!/bin/bash
# pmulti_video_qt 统一构建接口 (M1 规范 v0.1)
# 用法: bash release.sh [ARCH] [VERSION]
#   ARCH:    arm64（默认，设备 SE7）
#   env OUTPUT_DIR: 产物目录（默认 <repo>/output/pmulti_video_qt/）
#
# ⚠️ 障碍说明 (M3):
#   本工程依赖设备侧 SDK —— libsophon / sophon-ffmpeg / sophon-opencv
#   (pro 文件引用 /opt/sophon/libsophon-current 等绝对路径), 且按 readme
#   约定"默认配置为在 SE7 上编译"。统一构建镜像内不预置这些 SDK,
#   因此本脚本检测到 SDK 缺失时如实报告障碍并返回非 0, 不掩盖不跳过。
#   修复路径: 在镜像内预装 libsophon + sophon-mw 设备侧 SDK 后即可编译。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARCH="${1:-arm64}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT/output/pmulti_video_qt}"

# SDK 探测
HAS_LIBSOPHON=0; HAS_SDK=0
[ -d /opt/sophon/libsophon-current ] || [ -d /opt/sophon/libsophon ] && HAS_LIBSOPHON=1
[ -d /opt/sophon/sophon-ffmpeg-latest ] && HAS_SDK=1

if [ "$HAS_LIBSOPHON" = "0" ] || [ "$HAS_SDK" = "0" ]; then
  echo "ERROR: pmulti_video_qt 依赖设备侧 SDK 缺失:"
  echo "  - libsophon:      /opt/sophon/libsophon-current  [缺失]"
  echo "  - sophon-ffmpeg:  /opt/sophon/sophon-ffmpeg-latest  [缺失]"
  echo "  - sophon-opencv:  /opt/sophon/sophon-opencv-latest  [缺失]"
  echo "说明: 该工程按 readme 约定在 SE7 设备上现场编译, 统一镜像未预装设备 SDK。"
  echo "      待镜像预装 libsophon+sophon-mw 后可接入。"
  exit 3
fi

echo "==> pmulti_video_qt build arch=$ARCH (SDK 就绪)"
mkdir -p "$OUTPUT_DIR"
pushd "$SCRIPT_DIR/source" >/dev/null
rm -rf build && mkdir build && cd build
qmake ..
make -j"$(nproc)"
cp multi_video_qt "$OUTPUT_DIR/"
popd >/dev/null

echo "==> pmulti_video_qt 完成, 产物: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"
