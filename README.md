# miniEasyConnect

轻量的 Apple 芯片 Mac VPN 客户端。使用 SwiftUI 原生界面与 [ZJU Connect](https://github.com/Mythologyli/zju-connect) 核心，让应用直接访问 EasyConnect 授权内网，无需逐个配置代理。

[下载 v1.0.1](https://github.com/yjcdon/miniEasyConnect/releases/tag/v1.0.1) · [v1.1 验收记录](Docs/v1.1-验收记录.md) · [AGPL-3.0](LICENSE)

## 功能

当前源码为 **v1.1.0（build 4）**，公开下载与 Homebrew 版本为 **v1.0.1**。以下功能描述对应 v1.1 源码。

- 应用包自带核心，日常使用填写地址、账号和密码即可，无需安装 Go 或操作命令行。
- 点击顶部大图标连接最近记录，连接中点击取消，已连接时点击断开；没有记录时打开新建表单。
- 表单仅“保存”记录；连接通过大图标、记录按钮或菜单单独发起。修改当前记录时保持原会话，保存后的连接信息用于下一次显式连接。
- 密码支持显示与隐藏并保存在系统钥匙串；备注位于表单最后。记录行提供修改和删除图标，删除前再次确认。
- 固定窗口采用状态区 40%、记录区 60% 的布局；新增、修改和删除为统一 28 pt 按钮。
- 关闭窗口后保持连接；菜单栏图标可手动移除，再从应用菜单恢复。按 ⌘Q 退出时先断开并恢复本次修改的网络设置。

当前接入 **EasyConnect** 协议。业务流量按服务端授权资源和路由访问；连接期间 DNS 优先使用 VPN 提供的解析服务，因此公网域名的解析路径也可能变化。

## 下载与安装

支持 **Apple Silicon（M 系列芯片）**，最低构建目标为 **macOS 13**。v1.1 源码在 **macOS 27.2** 上进行实机验证；v1.0.1 的既有验证见[原验收记录](Docs/验收记录.md)。其他系统版本和服务端配置按实际验证结果确认。

1. 下载 [miniEasyConnect-v1.0.1-macos-arm64.zip](https://github.com/yjcdon/miniEasyConnect/releases/download/v1.0.1/miniEasyConnect-v1.0.1-macos-arm64.zip)。
2. 解压，将 `miniEasyConnect.app` 拖入“应用程序”，再打开应用。
3. v1.0.1：点击“+”，填写地址（如 `vpn.example.com:443`）、账号和密码后提交连接。源码构建的 v1.1：先保存记录，再点击大图标或记录按钮连接。
4. 首次连接按应用提示，在系统设置中批准后台辅助服务，再返回点击“已允许，继续连接”。普通连接与重连复用这次批准。

### Homebrew 安装

```sh
brew tap yjcdon/minieasyconnect https://github.com/yjcdon/miniEasyConnect
brew install --cask yjcdon/minieasyconnect/minieasyconnect
```

Homebrew 下载同一个 v1.0.1 应用包并校验 SHA-256，仅支持 Apple Silicon 与 macOS 13 或更新版本。首次打开的安全提示和后台服务批准步骤与手动安装相同。

如果此前已手动安装，先退出应用，再执行 Homebrew 安装并按提示处理同路径的现有应用。第三方清理工具可能连带清理应用数据，升级前请保留本机连接记录。使用 Homebrew 卸载前，仍需先在应用菜单中选择“停用后台服务…”，再执行 `brew uninstall --cask yjcdon/minieasyconnect/minieasyconnect`。

### 首次打开的安全提示

**v1.0.1 使用 Apple Development 开发签名，公证状态为未公证。** macOS 可能阻止首次打开。

确认下载来源可信后，先尝试打开一次，再到“系统设置 → 隐私与安全性”，找到该应用的提示并点击“仍要打开”，按系统提示确认。具体步骤见 [Apple：在 Mac 上安全地打开 App](https://support.apple.com/zh-cn/102445)。系统策略或受管理设备可能限制此操作。

如果 VPN 服务端使用系统不信任的证书，应用会显示证书指纹。核对后确认，批准结果按连接地址保存在本机；证书变化时需重新确认。

## 本地数据与隐私

连接地址、账号、备注等记录保存在用户目录下的 `~/Library/Application Support/miniEasyConnect/connections.json`；密码单独保存在系统钥匙串。最近使用记录和已批准的证书指纹保存在本机偏好设置中。这些运行数据不写入 `.app` 应用包。

应用只在本机管理连接，认证与业务通信发送到你配置的 VPN 服务端及授权资源。

## 升级与卸载

**升级：** 先选择“退出 miniEasyConnect”或按 `⌘Q`，等待断开和网络恢复完成，再替换整个应用包。连接记录和钥匙串密码保存在应用包之外。

**卸载：** 在屏幕顶部的“miniEasyConnect”应用菜单中选择“停用后台服务…”。应用会先断开并恢复网络，再注销后台服务；成功后退出应用，将其移到废纸篓。停用服务会保留连接记录和钥匙串密码；再次连接会重新启用服务，系统可能要求重新批准。

## 资源占用与验证范围

v1.1 最终包稳定连接的短时采样约 **58–60 MB**，统计界面、辅助服务和核心的 physical footprint 总和。窗口状态、输入操作后的稳态、启动峰值与传输负载分别记录，最终候选包结果见 [v1.1 验收记录](Docs/v1.1-验收记录.md)。

当前已完成控制器临时 CLI 验证（86 个断言）、相关 Go 测试与 vet、编译及签名校验。已有真实网络验证包含授权内网 HTTP 200 和公网验证端点 HTTP 204，最终候选包的实连与退出恢复单独记录。跨 macOS 版本、真实睡眠唤醒、长期传输和辅助功能覆盖以实际验收范围为准。

## 从源码构建

需要 Apple 芯片 Mac、macOS 13 或更新版本、Xcode Command Line Tools、Go **1.27.3** 和有效的 **Apple Development** 代码签名身份。当前实测工具链为 Swift 6.4（Swift 5 语言模式）；构建脚本固定使用 Go 1.27.3，并调用系统 `python3` 生成构建清单和第三方声明。

```sh
git clone https://github.com/yjcdon/miniEasyConnect.git
cd miniEasyConnect
./Scripts/build.sh
open dist/miniEasyConnect.app
```

脚本默认选择本机可用的 Apple Development 或 Developer ID Application 身份，也可通过 `MINIEASY_SIGN_ID` 指定证书名称或哈希。Apple Development 签名不使用安全时间戳；Developer ID Application 签名需联网访问 Apple 时间戳服务。脚本完成签名和校验；Developer ID 的实际签名与公证分发尚未完成实测。证书和私钥由构建者自行配置。

版本由 `VERSION` 和 `BUILD_NUMBER` 管理。应用内 `Contents/Resources/BuildManifest.json` 记录源码版本、上游基线、工具链以及辅助服务和核心的 SHA-256，便于核对构建来源。

## 项目文档与许可证

- [产品方案](Docs/产品方案.md)
- [技术方案](Docs/技术方案.md)
- [任务清单](Docs/任务清单.md)
- [验收记录](Docs/验收记录.md)
- [v1.1 技术方案](Docs/v1.1-技术方案.md)
- [v1.1 任务清单](Docs/v1.1-任务清单.md)
- [v1.1 测试用例](Docs/v1.1-测试用例.md)
- [v1.1 验收记录](Docs/v1.1-验收记录.md)
- [核心适配说明](Core/README.md)
- [第三方声明](Resources/ThirdParty/README.md)

本项目采用 [AGPL-3.0](LICENSE)。核心基于 [ZJU Connect](https://github.com/Mythologyli/zju-connect)，上游源码、修改和许可证保存在 [Core/upstream](Core/upstream)，基线见 [UPSTREAM_REVISION](Core/UPSTREAM_REVISION)。应用包附带项目许可及实际构建依赖的第三方声明；图标基于 MIT 许可的 Tabler Icons。
