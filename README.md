# miniEasyConnect

**miniEasyConnect 是面向 Apple Silicon Mac 的轻量 EasyConnect VPN 客户端**，使用 SwiftUI 原生界面和 [ZJU Connect](https://github.com/Mythologyli/zju-connect) 核心，连接 VPN 服务端授权的内网资源。

适合希望用简单界面连接 EasyConnect 内网的 Mac 用户。应用自带核心，日常使用无需安装 Go 或操作命令行；服务端兼容性取决于实际认证方式和配置。

[下载 v1.1.0](https://github.com/yjcdon/miniEasyConnect/releases/tag/v1.1.0) · [验收记录](Docs/v1.1-验收记录.md) · [AGPL-3.0](LICENSE)

## 功能

- 一键连接：点击大图标连接最近使用的记录，连接中点击取消，已连接时点击断开。
- 保存多条连接：管理地址、账号、密码和备注；表单点击“保存”后，通过大图标或记录按钮发起连接。
- 保护本机凭据：密码保存在 macOS 钥匙串，输入框支持显示和隐藏；删除记录前再次确认。
- 后台保持连接：关闭窗口或移除菜单栏图标后继续运行，从应用菜单可恢复菜单栏图标。
- 退出恢复网络：按 `⌘Q` 先断开并恢复本次修改的网络设置，再退出界面、辅助服务和核心。

## 系统要求与安装

支持 **Apple Silicon（M 系列芯片）**，最低构建目标为 **macOS 13 Ventura**。v1.1.0 在 macOS 27.2 上完成实机连接验证，其他 macOS 版本及 VPN 服务端的兼容性仍需实际验证。

### Homebrew

```sh
brew tap yjcdon/minieasyconnect https://github.com/yjcdon/miniEasyConnect
brew install --cask yjcdon/minieasyconnect/minieasyconnect
```

已通过 Homebrew 安装的用户可执行：

```sh
brew update
brew upgrade --cask yjcdon/minieasyconnect/minieasyconnect
```

### 下载 App

下载 [miniEasyConnect-v1.1.0-macos-arm64.zip](https://github.com/yjcdon/miniEasyConnect/releases/download/v1.1.0/miniEasyConnect-v1.1.0-macos-arm64.zip)，解压后将 `miniEasyConnect.app` 拖到“应用程序”。Release 附带 `SHA256SUMS`，Homebrew 使用同一应用包并校验 SHA-256。

**当前版本使用 Apple Development 开发签名，尚未经过 Apple 公证。** 首次打开若被 macOS 阻止，确认来源后，到“系统设置 → 隐私与安全性”点击“仍要打开”。参见 [Apple 安全打开 App 说明](https://support.apple.com/zh-cn/102445)。受管理设备可能有额外限制。

## 开始使用

1. 点击“+”，填写 VPN 地址（例如 `vpn.example.com:443`）、账号、密码及可选备注，点击“保存”。
2. 点击大图标或记录的“连接”按钮。
3. 首次连接按提示在系统设置中批准后台辅助服务，再返回应用继续连接；日常连接复用这次批准。
4. 连接成功后访问授权内网。点击大图标断开，按 `⌘Q` 完整退出。

如果服务端证书不受系统信任，应用会显示证书指纹。核对后再批准；证书变化时需要重新确认。

## 常见问题

### 支持哪些 VPN？

miniEasyConnect 当前接入 **EasyConnect 协议**，核心基于 ZJU Connect。它面向服务端授权的内网访问，实际可用性取决于服务端认证方式、授权资源与策略。使用前需要有效的 VPN 地址和账号。

### 连接 VPN 后，公网和 DNS 会怎样？

业务流量按服务端授权资源和路由处理。连接期间 DNS 优先使用 VPN 提供的解析服务，因此公网域名解析路径也可能变化。与 Clash 等代理同时使用时，需要按自己的网络和域名规则配置分流。

### 内存占用是多少？

v1.1.0 在本机真实连接后的短时空闲采样中，界面、辅助服务与核心三个进程的 **physical footprint 合计约 58–60 MB**。这是特定设备与连接场景的测量，不能代表长期运行或传输峰值。采样方法、范围和测试边界见 [v1.1 验收记录](Docs/v1.1-验收记录.md)。

### 下载的 App 会包含他人的连接信息吗？

连接记录与密码保存在各用户本机，不写入 `.app`。地址、账号和备注保存在 `~/Library/Application Support/miniEasyConnect/connections.json`，密码单独保存在系统钥匙串；最近记录、菜单栏偏好与证书批准保存在本机偏好设置中。

## 升级与卸载

**升级：** 按 `⌘Q`，等待网络恢复和应用退出后再更新。连接记录与密码存储在应用包之外；第三方清理工具可能连带清理应用数据。

**卸载：** 先从应用菜单选择“停用后台服务…”，待应用恢复网络、注销服务并退出，再将 App 移到废纸篓。Homebrew 用户随后执行 `brew uninstall --cask yjcdon/minieasyconnect/minieasyconnect`。停用服务保留连接记录和钥匙串密码；以后重新启用可能需要系统批准。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools、Go **1.27.3**、系统 `python3` 和有效的 Apple Development 或 Developer ID Application 签名身份。实测工具链为 Swift 6.4，使用 Swift 5 语言模式及 macOS 13 ARM64 构建目标。

```sh
git clone https://github.com/yjcdon/miniEasyConnect.git
cd miniEasyConnect
./Scripts/build.sh
open dist/miniEasyConnect.app
```

构建脚本自动选择可用签名身份，也可设置 `MINIEASY_SIGN_ID`。Apple Development 签名使用本机开发证书；Developer ID 签名需要联网获取 Apple 时间戳，公证分发仍需构建者自行处理。

`VERSION` 与 `BUILD_NUMBER` 管理版本。应用内 `Contents/Resources/BuildManifest.json` 记录源码提交、上游基线、工具链及辅助服务和核心的 SHA-256。

## 文档与许可

- [产品方案](Docs/产品方案.md) · [技术方案](Docs/技术方案.md)
- [v1.1 技术方案](Docs/v1.1-技术方案.md) · [任务清单](Docs/v1.1-任务清单.md) · [测试用例](Docs/v1.1-测试用例.md) · [验收记录](Docs/v1.1-验收记录.md)
- [核心适配说明](Core/README.md) · [第三方声明](Resources/ThirdParty/README.md)

miniEasyConnect 采用 [AGPL-3.0](LICENSE)。核心基于 [ZJU Connect](https://github.com/Mythologyli/zju-connect)，上游源码、修改与许可证保存在 [Core/upstream](Core/upstream)，基线见 [UPSTREAM_REVISION](Core/UPSTREAM_REVISION)。App 附带项目许可和实际构建依赖的第三方声明。应用图标基于 MIT 许可的 Tabler Icons。
