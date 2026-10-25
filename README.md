# miniEasyConnect

轻量的 Apple 芯片 Mac VPN 客户端。SwiftUI 原生界面，复用 [ZJU Connect](https://github.com/Mythologyli/zju-connect) 核心，通过 TUN 让应用直接访问授权内网。

开发进行中。实际支持范围与资源占用将在集成验证后公布。

最终应用包自带已编译核心，日常使用不需要安装 Go 或操作命令行。

- 输入地址、账号和密码连接。
- 保存连接记录，可填写备注；修改备注无需断开连接。密码存入系统钥匙串。
- 关闭窗口继续运行，通过菜单栏断开或退出。
- 断开时恢复应用修改的网络设置。

## 构建

需要 Apple 芯片 Mac、macOS 13 或更新版本、Xcode Command Line Tools、Go，以及用于辅助服务身份校验的 Apple 代码签名证书。

```sh
./Scripts/build.sh
open dist/miniEasyConnect.app
```

默认选择本机可用的 Apple Development 或 Developer ID Application 签名身份；也可通过 `MINIEASY_SIGN_ID` 指定。私钥和证书不属于项目源码。开发签名的构建不等同于已公证的公开分发版本。

版本由 `VERSION` 和 `BUILD_NUMBER` 统一管理。应用内的 `Contents/Resources/BuildManifest.json` 记录同次构建的版本、源码提交及本地修改状态、上游基线、工具链和辅助服务/核心的 SHA-256；不包含本机路径或签名身份。源码归档没有 Git 元数据时，源码提交状态明确记为 `null`。清单由外层应用签名保护，内嵌文件可按哈希核对。

首次连接需要在系统设置中允许辅助服务执行网络操作；批准后普通连接与重连复用授权。私有证书首次明确确认后会按地址记住，同一证书不反复询问。

## 升级与卸载

升级前选择“退出 miniEasyConnect”，等待应用完成断开和网络恢复后，再替换整个应用包。日常断开和退出会保留后台服务注册，不需要每次重新批准。

卸载前，在屏幕顶部的“miniEasyConnect”应用菜单中选择“停用后台服务…”。确认后，应用会先断开并恢复网络，再注销后台服务；失败时会提示原因。停用成功后退出应用，将应用移到废纸篓。此操作保留连接记录和钥匙串密码；再次连接时会重新启用后台服务，系统可能要求重新批准。

## 项目文档

- [产品方案](Docs/产品方案.md)
- [技术方案](Docs/技术方案.md)
- [任务清单](Docs/任务清单.md)
- [验收记录](Docs/验收记录.md)

## 许可证

本项目采用 AGPL-3.0，保留 ZJU Connect 及其依赖的原有声明。构建使用的核心源码和适配包含在本仓库中。
