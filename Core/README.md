# miniEasyConnect 核心

`upstream` 保留 ZJU Connect 的 Go 源码及许可证，基线为公开提交 `c19eb4ed34b9cf6e8e8ea3315fe9973c8411eb63`。不包含上游 Git 目录和无关部署图片。本项目不会修改旁边的独立上游 checkout。

构建入口：在 `Core/upstream` 执行 `go build ./cmd/minieasyconnect-core`，目标平台为 `darwin/arm64`。Go 工具链及依赖以 `go.mod`、`go.sum` 为准。

## 适配范围

- 新增 `cmd/minieasyconnect-core`：每个进程只管理一次连接，通过私有 JSONL 管道收发命令、状态和认证挑战。
- EasyConnect 客户端新增 `VerifyServerCertificate` 和 `PinnedCertificateSHA256` 选项。适配入口先做无凭据 TLS 探测并执行系统信任和主机名校验；验证失败时必须匹配已批准的精确证书指纹，或由用户明确批准本次指纹。
- 获批准的证书指纹同时约束登录 HTTP、Token 和特殊隧道握手。任何不同的证书均被拒绝，不提供任意忽略证书错误的开关。
- TUN 新增 `Prepare`、`RunContext`、`InterfaceName` 和 `Close`，用于明确握手就绪、双向传输错误和资源归属。取消时中断拨号与 DNS I/O，退出时结束两个传输循环。
- 系统 DNS 始终由 Swift 辅助服务管理，适配入口不调用上游 CLI 初始化钩子。
- 路由安装前发送计划并等待辅助服务 `configure` 确认；DNS 的 UDP/TCP 监听均绑定实际虚拟网卡地址。
- 服务端授权域名的 A 记录进入 IPPool，并在返回 DNS 响应前通过同一确认流程添加必要的动态路由。动态路由和 DNS 地址映射限制为 4096 项，并发 DNS 请求限制为 64 个。
- DNS 请求通过服务端指定的 DNS 转发，不回退到公共 DNS；原始日志默认丢弃，不混入协议或写入磁盘。
- 修复单方向握手失败时已经建立的连接未释放，以及读写重连后未实际重试 I/O 的问题；连接关闭不等待阻塞中的读写锁。
- loopback IP 目标直接走本机回环，不绑定物理网卡；普通 VPN 服务端仍沿用物理出口选择。

## 管道协议

所有消息携带 `version: 1` 和本次连接的 `sessionID`。标准输出仅用于事件，输入管道关闭即终止连接。

命令：`start`、`configure`、`answer`、`stop`。`start.config` 包含 `serverHost`、`serverPort`、`username`、`password`，以及可选的 `trustedCertificateSHA256`。凭据不进入命令行或配置文件。

事件：`phase`、`challenge`、`ready`、`failed`、`stopped`。`phase` 带 `interfaceName`、`dnsAddress`、`routes` 时，辅助服务先记录网络变更计划，再返回 `configure`。每次计划都携带完整路由列表，并串行等待对应确认；连接后的动态域名路由更新沿用此流程，不改变界面的已连接状态。`ready` 在隧道握手、路由安装、UDP/TCP DNS 监听和一次实际隧道 DNS 请求完成后发出。

认证挑战支持文本验证码与图片验证码；需要点击图片或外部登录的挑战明确返回不支持，由调用方提示处理。

`challengeKind: certificate` 表示系统验证未通过，`certificateSHA256` 和消息展示探测到的 leaf SHA-256 指纹。只有 `answer: trust` 才批准该精确证书；拒绝或关闭连接会取消。本次实际使用的指纹也会随 `ready` 返回，便于界面按连接地址保存已批准指纹。探测和批准完成前不发送登录 HTTP 请求或凭据。

完整公开分发应同时提供本目录中的修改源码、构建说明和上游 AGPL-3.0 许可证。
