# bmssm

Sophon System Management 服务（由 bmssm 现代化重写）。

## 编译
- x86（开发机/PCIE 主机，宿主 gcc 动态链接）: `bash build/build-bmssm.sh`
- arm64（设备端，musl 全静态链接）: `bash build/build-bmssm-arm64.sh`（musl 工具链自动获取）
- 统一入口: `bash release.sh [arm64|amd64|all] [VERSION]`（产物到 `$OUTPUT_DIR`，默认 `<repo>/output/pbmssm/`）

## 配置
默认读取 `/etc/bmssm/conf/bmssm.yaml`，本地开发回退 `./config/bmssm.yaml`。

## 端口
9779