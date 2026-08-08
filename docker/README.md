# sophon-tools-build —— sophon-tools 统一编译镜像

`docker/` 目录是 sophon-tools 17 子项目的统一构建镜像交付物。镜像预装全部子项目所需工具链，
子项目构建只需基于此镜像，不再依赖构建机预装环境。

## 一条命令构建镜像

```bash
# 基础镜像（不含 dfss 私有工具链 sw_64/loongarch64）
bash docker/build.sh

# 完整镜像（内置 dfss 私有工具链，需先在 13.24 服务器上执行导出脚本）
bash docker/build.sh --with-dfss-toolchains

# 指定标签 / 禁用缓存
bash docker/build.sh --tag v1.0 --no-cache
```

### 版本锁定（可复现）

- 唯一版本源：`docker/versions.env` —— 全部工具链版本 + 校验和统一在此维护。
- 基础镜像 `ubuntu:22.04` 用 **digest**（不可变引用）锁定，不用 tag。
- Go / Node 下载后做 **SHA256 校验**（校验失败即中止构建）。
- Rust 用 rustup 锁定稳定版 `1.97.1`；musl 工具链来自 musl.cc。
- 想固定 musl 工具链内容：把首次构建打印的实际 SHA256 填入 `versions.env` 的 `MUSL_*_SHA256`。

## 镜像内工具链（对照 M1 盘点清单）

| 子项目 | 工具链 | 版本 |
|--------|--------|------|
| pbmssm / psophliteos | Go | 1.25.5（含 arm64/amd64 交叉） |
| pbm_set_ip | Rust + cargo | 1.97.1（aarch64/x86_64 musl + aarch64 gnu target） |
| psophliteos 前端 | Node + pnpm + yarn | Node 20.19.0 / pnpm 9.15.9 / yarn 1.22.22 |
| pbmssm / pbm_set_ip | musl 交叉工具链 | aarch64 + x86_64（musl.cc 静态） |
| pdfss_cpp | glibc 交叉工具链 | aarch64 / armel / riscv64（apt 精确版本） |
| pdfss_cpp (windows) | mingw-w64 | x86_64-w64-mingw32 + i686-w64-mingw32 |
| pdfss_cpp (私有) | sw_64 + loongarch64 | SWREACH GCC 8.3.0 / LoongArch 8.3.0（dfss 私有源） |
| pqt 系列 | Qt 5 + qmake | qtbase5-dev（AppImage 依赖） |
| 打包/文档 | dpkg-deb / 7z / zip / upx / patchelf / pandoc | apt 精确版本 |
| 跨架构验证 | qemu-user-static | aarch64 / loongarch64 等 |

## dfss 私有工具链（sw_64 / loongarch64）

sw_64 和 loongarch64 工具链来自 dfss 私有源，**默认不内置**（体积大、需从 13.24 服务器容器导出）。
两种获取方式：

### 方式 1：从 13.24 服务器容器导出（推荐）

在 13.24 服务器上（`cross_build_sophon_u20:v1` 容器，名 `bm1684_zzt`），执行：

```bash
bash docker/scripts/export-dfss-toolchains.sh
# 产物: docker/toolchains/swgcc830_cross_tools.tar.zst
#        docker/toolchains/loongarch64-cross-tools.tar.zst
```

然后构建：

```bash
bash docker/build.sh --with-dfss-toolchains
```

### 方式 2：从 dfss 私有服务器在线拉取

网络可达 dfss 服务器时，可参考 `source/pdfss_cpp/build_docker/Dockerfile` 的方式：

```bash
python3 -m dfss --url=open@sophgo.com:/toolchains/swgcc830-*.tar.gz
```

## 挂载源码跑构建

```bash
# 挂载 sophon-tools 源码到 /workspace，进入容器交互式构建
docker run -it --rm \
  -v "$(pwd)":/workspace/sophon-tools \
  sophon-tools-build:latest \
  bash

# 进入后，按各子项目方式构建，例如:
cd /workspace/sophon-tools/source/pbmssm
bash build/build-deb-bmssm.sh   # 需以非 root 用户运行，或改输出目录为可写路径
```

### 单条命令跑某个子项目构建

```bash
docker run --rm \
  -v "$(pwd)":/workspace/sophon-tools \
  -w /workspace/sophon-tools \
  sophon-tools-build:latest \
  bash -c 'cd source/pbmssm && bash build/build-deb-bmssm.sh'
```

## 镜像自检

```bash
# 基础自检（工具链存在性）
bash docker/verify.sh

# 完整自检（含交叉编译实测：arm64 musl 静态 / windows / sw_64 / loongarch64）
bash docker/verify.sh --cross
```

## pqt 系列（Qt GUI 工具）专用构建

`docker/pqt/` 提供 pqt 系列（`pqt_memory_edit` 图形化内存修改工具、`pqt_batch_deployment` 批量部署工具）的专用构建。

> **为什么独立镜像**：pqt 打 AppImage 依赖 linuxdeployqt，它强制宿主 glibc ≤ 2.31
> （保证产物在旧发行版可运行）。sophon-tools-build 基于 22.04（glibc 2.35）不满足，
> 故 pqt 专用镜像基于 ubuntu:20.04（glibc 2.31）。

```bash
# linux AppImage 一键编译（自动生成 memory_edit.tar.xz 前置依赖）
bash docker/pqt/build-pqt.sh --project pqt_memory_edit --linux
bash docker/pqt/build-pqt.sh --project pqt_batch_deployment --linux

# windows exe（需先交叉编译 Qt mingw 静态库，一次约 1-2 小时）
bash docker/pqt/build-qt-mingw.sh          # 交叉编译 Qt 5.15.2 mingw 静态
bash docker/pqt/build-pqt.sh --project pqt_memory_edit --windows

# 两端一起
bash docker/pqt/build-pqt.sh --project pqt_memory_edit --all
```

已实测：`qt_mem_edit_V2.12.1-x86_64.AppImage`（25.9MB）在 ubuntu:20.04 镜像内一键产出，
AppImage 可正常解包运行。

## 交叉编译示例

`docker/examples/cross-test/` 提供 C / Rust / Windows 的交叉编译最小示例：

```bash
bash docker/examples/cross-test/run.sh --image sophon-tools-build:latest
```

## 已知边界

1. **pqt 系列 AppImage** 用专用镜像 `sophon-tools-build-pqt`（ubuntu:20.04，glibc 2.31）构建，产物兼容 glibc ≥ 2.27 的系统。
2. **pSophUI / pmulti_video_qt** 需要交叉 Qt / libsophon SDK，本镜像不含（M3 处理）。
3. **pdfss_cpp libs 编译**（libssh2/mbedtls/zlib 静态）耗时较长，建议镜像内预编一次（build_libs.sh）。
4. **dfss 私有工具链**默认不内置；需要时按上文方式导出。
5. 容器内构建涉及 `sudo` 的脚本（根 `release.sh`）需以 root 运行（镜像默认 root）或调整输出目录权限。
6. **pqt windows 端**依赖 Qt 5.15 mingw 静态库（`build-qt-mingw.sh` 交叉编译，1-2 小时），
   仓库 `libs/win_amd64` 只含 libssh2/openssl，不含 Qt。

## 目录结构

```
docker/
├── Dockerfile                # 多阶段构建（Stage1 下载校验 → Stage2 汇入）
├── versions.env              # 唯一版本源（版本 + 校验和）
├── build.sh                  # 一条命令构建镜像
├── verify.sh                 # 镜像自检（对照 M1 清单）
├── README.md                 # 本文件
├── scripts/
│   └── export-dfss-toolchains.sh  # 从 13.24 容器导出 sw_64/loongarch64 工具链
├── pqt/
│   ├── Dockerfile            # pqt 专用镜像（ubuntu:20.04，glibc 2.31）
│   ├── build-pqt.sh          # pqt linux/windows 一键编译
│   └── build-qt-mingw.sh     # Qt 5.15.2 mingw 静态库交叉编译
├── examples/
│   └── cross-test/           # 交叉编译示例（C/Rust/Windows）
└── toolchains/               # 导出的私有工具链归档（构建时由 --with-dfss-toolchains 使用）
```
