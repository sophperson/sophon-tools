# syntax=docker/dockerfile:1
# =============================================================================
# sophon-tools-build-pqt —— pqt 系列(Qt GUI 工具)专用构建镜像
#
# 为什么独立于 sophon-tools-build:
#   pqt 系列打 AppImage 依赖 linuxdeployqt, 而 linuxdeployqt 强制要求宿主 glibc <= 2.31
#   (以保证产物在旧发行版可运行, https://github.com/probonopd/linuxdeployqt/issues/340)。
#   sophon-tools-build 基于 ubuntu:22.04 (glibc 2.35) 无法满足; 本镜像基于 ubuntu:20.04
#   (glibc 2.31), 同时提供 Qt 5 + openssl 1.1 兼容, 满足 pqt 系列 linux/AppImage 构建。
#
# 构建:  bash docker/pqt/build-pqt.sh --linux
# 也可直接从 13.24 服务器镜像复用: docker pull (registry)
# =============================================================================

ARG UBUNTU_PQT_DIGEST="ubuntu@sha256:8feb4d8ca5354def3d8fce243717141ce31e2c428701f6682bd2fafe15388214"

FROM ${UBUNTU_PQT_DIGEST}

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

SHELL ["/bin/bash", "-c"]

# ---- 系统依赖: Qt5 开发包 + 构建工具 + AppImage 打包依赖 ----
# qtbase5-dev qttools5-dev -> Qt 5.12.8 (ubuntu 20.04), libgl1-mesa-dev 提供 OpenGL 头
# libfuse2 供 AppImage 运行时; patchelf 供 linuxdeployqt 重写 ELF
RUN apt-get update && apt-get install -y --no-install-recommends \
        qtbase5-dev qttools5-dev qttools5-dev-tools \
        build-essential gcc g++ make cmake \
        git wget curl ca-certificates \
        libgl1-mesa-dev libglib2.0-0 \
        patchelf libfuse2 fuse \
        file binutils \
    && rm -rf /var/lib/apt/lists/*

# ---- openssl 1.1 ----
# pqt 仓库自带的 libssh2 按 ubuntu18.04 (openssl 1.1.1) 编译, 依赖 libcrypto.so.1.1 符号。
# ubuntu20.04 默认就是 openssl 1.1.1, 与 18.04 完全兼容, 无需额外处理。

WORKDIR /workspace
RUN git config --global --add safe.directory "*"

CMD ["/bin/bash"]
