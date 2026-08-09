# sophliteos

算力设备管理系统（SophLiteOS）—— Sophgo 算力设备的 Web 管理平台，提供设备资源监控、告警、日志、网络/IP、密码、OTA/SSM 升级、版本等设备运维功能。

> 本子工程自 `sophgo-liteos` 迁入并裁剪掉 algoliteos 算法业务集成。

## 目录结构
- `api`: 后端业务控制器（device-mgmt handlers）
- `router`: 路由定义
- `client/bmssm`: 设备端 SSM(System Service Manager, 127.0.0.1:9779) 接口客户端
- `client/httpclient`: 通用 HTTP 封装
- `mvc`: 参数封装/验证/返回/i18n/异常
- `middleware`: 鉴权/熔断/超时中间件
- `database`: sqlite（User/Alarm/OptLog）
- `config`/`logger`/`global`/`initialization`: 配置/日志/全局/初始化
- `frontend`: Vue 前端（基于 vue-vben-admin），源码已在本目录下
- `build`/`scrip`/`release`: 构建脚本/部署脚本/产物落点

## 编译依赖
- go >= 1.19
- arm64 静态交叉编译需要 aarch64-linux-musl-gcc（由 `build/fetch-musl-toolchain.sh` 自动下载，也可用系统包预装）
- 前端构建需要 pnpm（或 yarn 兜底）

## 构建（统一接口，推荐）

前端源码已在本目录 `frontend/` 下，**无需 clone**。在子项目根执行：

```bash
bash release.sh [arm64|amd64|all] [VERSION]   # 默认 arm64 / 2.1.0
```

或直接出单个 deb：

```bash
bash build/build-deb-sophliteos.sh [VERSION] [soc|pcie]
```

产物落到 `release/`（`OUTPUT_DIR` 可指定输出目录），如 `release/sophliteos_soc_2.1.0.deb`、`release/sophliteos_pcie_2.1.0.deb`。

> `build/build_2_release.sh`、`build/build_test.sh`、`scrip/package.sh`、`build/package-deb-sdk.sh`
> 是旧 docker-node16 + tgz 流程，已废弃，仅供回溯。

## 产物
```
release/
├── sophliteos_soc_2.1.0.deb      # arm64 设备版
└── sophliteos_pcie_2.1.0.deb     # amd64 开发机版
```

## 安装运行
```bash
sudo dpkg -i release/sophliteos_soc_2.1.0.deb     # arm 设备
sudo dpkg -i release/sophliteos_pcie_2.1.0.deb    # x86 开发机
```
安装后由 systemd 服务 `sophliteos` 拉起，监听 :8080。

---

## 登录页 LOGO 替换

登录页的 LOGO（`class="sophgo_logo"`）保留可替换，其余页面的 sophgo logo（顶部用户下拉 `__header`、菜单 `menu_logo`、应用 `logo.png`、登录表单 `logo.png`）已移除。

替换登录 LOGO 的两种方式：

### 方式一：替换部署后的图片文件（无需重新构建）

sophliteos 静态资源从 `/opt/sophon/sophliteos/dist/resource/` 提供，登录 LOGO 默认读取 `resource/img/login_logo.png`。

```bash
# 替换为目标 LOGO（建议 PNG，contain 缩放）
sudo cp /path/to/your_logo.png /opt/sophon/sophliteos/dist/resource/img/login_logo.png
```

浏览器强刷（Ctrl+Shift+R）即可生效。

> 注意：sophliteos deb 升级会刷新 `/opt/sophon/sophliteos/dist`，升级后需重新覆盖此文件。

### 方式二：构建期注入自定义路径（持久，随升级保留）

在 `source/psophliteos/frontend/.env`（或对应模式的 `.env.production`）设置：

```bash
# 任意可访问的 URL/路径，置空则不显示 LOGO
VITE_GLOB_LOGIN_LOGO = /resource/img/your_login_logo.png
```

把你的 LOGO 放进 `source/psophliteos/frontend/public/resource/img/your_login_logo.png`，重新构建 deb：

```bash
cd source/psophliteos
bash build/build-deb-sophliteos.sh 2.0.7 soc
sudo dpkg -i release/sophliteos_soc_2.0.7.deb
```

该路径随 dist 打包，升级后保留。

### 接口说明

- `Login.vue` 通过 `import.meta.env.VITE_GLOB_LOGIN_LOGO` 读取 LOGO 路径（默认 `/resource/img/login_logo.png`），内联注入 `.sophgo_logo` 的 `background-image`。
- `VITE_GLOB_APP_HIDE_MENU_LOGO=true` 可隐藏整个登录 LOGO。
