# miniEasyConnect

轻量的 Apple 芯片 Mac VPN 客户端。SwiftUI 原生界面，复用 [ZJU Connect](https://github.com/Mythologyli/zju-connect) 核心，通过 TUN 让应用直接访问授权内网。

开发进行中。实际支持范围与资源占用将在集成验证后公布。

最终应用包自带已编译核心，日常使用不需要安装 Go 或操作命令行。

- 输入地址、账号和密码连接。
- 保存连接记录，密码存入系统钥匙串。
- 关闭窗口继续运行，通过菜单栏断开或退出。
- 断开时恢复应用修改的网络设置。

## 构建

需要 Apple 芯片 Mac、macOS 13 或更新版本、Xcode Command Line Tools、Go，以及用于辅助服务身份校验的 Apple 代码签名证书。

```sh
./Scripts/build.sh
open dist/miniEasyConnect.app
```

默认选择本机可用的 Apple Development 或 Developer ID Application 签名身份；也可通过 `MINIEASY_SIGN_ID` 指定。私钥和证书不属于项目源码。开发签名的构建不等同于已公证的公开分发版本。

首次连接需要在系统设置中允许辅助服务执行网络操作；批准后普通连接与重连复用授权。私有证书首次明确确认后会按地址记住，同一证书不反复询问。

## 项目文档

- [产品方案](Docs/产品方案.md)
- [技术方案](Docs/技术方案.md)
- [任务清单](Docs/任务清单.md)
- [验收记录](Docs/验收记录.md)

## 许可证

本项目采用 AGPL-3.0，保留 ZJU Connect 及其依赖的原有声明。构建使用的核心源码和适配包含在本仓库中。
