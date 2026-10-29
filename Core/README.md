# miniEasyConnect 核心

`upstream` 保留 ZJU Connect 的 Go 源码及许可证，公开基线提交记录在 [UPSTREAM_REVISION](UPSTREAM_REVISION)。不包含上游 Git 目录和无关部署图片。本项目不会修改旁边的独立上游 checkout。

构建入口：在 `Core/upstream` 执行 `go build ./cmd/minieasyconnect-core`，目标平台为 `darwin/arm64`。Go 工具链及依赖以 `go.mod`、`go.sum` 为准。

## 适配范围

- 新增 `cmd/minieasyconnect-core`：每个进程只管理一次连接，通过私有 JSONL 管道收发命令、状态和认证挑战。
- EasyConnect 客户端新增 `VerifyServerCertificate` 和 `PinnedCertificateSHA256` 选项。适配入口先做无凭据 TLS 探测并执行系统信任和主机名校验；验证失败时必须匹配已批准的精确证书指纹，或由用户明确批准本次指纹。
- 获批准的证书指纹同时约束登录 HTTP、Token 和特殊隧道握手。任何不同的证书均被拒绝，不提供任意忽略证书错误的开关。
- TUN 新增 `Prepare`、`RunContext`、`InterfaceName` 和 `Close`，用于明确握手就绪、双向传输错误和资源归属。取消时中断拨号与 DNS I/O，退出时结束两个传输循环。
- 系统 DNS 始终由 Swift 辅助服务管理，适配入口不调用上游 CLI 初始化钩子。
- 路由安装前发送计划并等待辅助服务 `configure` 确认；DNS 的 TCP 监听先在 `127.0.0.1` 分配不低于 1024 的随机空闲端口，UDP 使用同一端口，实际 TUN 地址只用于隧道传输。
- 辅助服务通过 `SCDynamicStore` 发布会话级临时 supplemental resolver，使用 `SupplementalMatchDomains: [""]` 将 VPN DNS 设为默认优先解析入口；保留原 `SCNetworkPreferences` 配置。更具体的既有 supplemental resolver 和 mDNS 仍按 macOS 系统规则选择。核心不截获其他 DNS 流量，不占用 53 端口或主动设置端口复用。
- 本地 DNS 先查服务端 `Dns.data` 静态映射，未命中时按顺序尝试服务端下发的全部可用 IPv4 DNS；不将 Rcs 授权资源或静态映射键视为完整 DNS 域名清单，也不以它们限制查询。`Dns.data` 第一段保持不透明，继续沿用上游名称到 IP 的映射约定。
- DNS 解析可能经过 VPN，业务连接仍按服务端授权资源和路由处理。解析成功不代表目标获得访问授权。就绪探测绕过静态映射，直接通过隧道查询 VPN DNS；任何有效 DNS 回答均证明该请求路径可用。
- 服务端授权域名的 A 记录进入 IPPool，并在返回 DNS 响应前通过同一确认流程添加必要的动态路由。动态路由和 DNS 地址映射限制为 4096 项，并发 DNS 请求限制为 64 个。
- DNS 请求使用服务端下发的全部可用 IPv4 DNS，保持配置顺序并去重，为所有上游添加必要的 53 端口资源和路由。不回退到公共 DNS；原始日志默认丢弃，不混入协议或写入磁盘。
- 每次 DNS 请求总预算为 8 秒，按剩余服务器数量均分剩余时间；每台服务器先使用不超过 3 秒且不超过本台预算一半的 UDP，失败或截断后 TCP 使用该台剩余预算，再尝试下一台。NXDOMAIN、SERVFAIL 等有效 DNS 回答直接返回，不转到另一台重解释。启动探测同时监听隧道及 DNS 监听错误，避免等探测超时才发现传输已退出。
- 本地监听失败、上游就绪探测失败和服务端 DNS 配置不可用分别返回 `dnsListenerFailed`、`dnsReadinessFailed`、`dnsUnavailable`，界面不接收原始错误或资源信息。
- 修复单方向握手失败时已经建立的连接未释放，以及读写重连后未实际重试 I/O 的问题；连接关闭不等待阻塞中的读写锁。
- 虚拟 IP 初始化连接由客户端字段持有并在替换或关闭客户端时释放，移除每 10 秒仅执行引用保留的空唤醒；真实会话保活继续运行。
- loopback IP 目标直接走本机回环，不绑定物理网卡；普通 VPN 服务端仍沿用物理出口选择。
- 登录响应校验必要的会话、RSA 字段和响应大小；普通 HTTPS 页面返回 `unsupportedServer`，不因缺失 XML 字段崩溃或自动重连。
- 只有服务端明确返回登录或验证 `Result=0` 才映射 `authenticationFailed`，只保留数字错误码，不在错误链中携带原始登录 XML。未知验证方式或无法识别的认证结果返回 `unsupportedAuthentication`。
- 登录、会话 Token 和虚拟 IP 初始化分别保留阶段与底层错误链；网络、证书或后续初始化失败不统一解释为账号密码错误。

## 管道协议

所有消息携带 `version: 1` 和本次连接的 `sessionID`。标准输出仅用于事件，输入管道关闭即终止连接。

命令：`start`、`configure`、`answer`、`stop`。`start.config` 包含 `serverHost`、`serverPort`、`username`、`password`，以及可选的 `trustedCertificateSHA256`。凭据不进入命令行或配置文件。

事件：`phase`、`challenge`、`ready`、`failed`、`stopped`。`phase` 带 `interfaceName`、`dnsAddress`、`routes` 时，辅助服务先记录网络变更计划，再返回 `configure`。每次计划都携带完整路由列表，并串行等待对应确认；连接后的动态域名路由更新沿用此流程，不改变界面的已连接状态。`ready` 在隧道握手、路由安装、UDP/TCP DNS 监听和一次实际隧道 DNS 请求完成后发出，并携带 `dnsAddress: "127.0.0.1"`、`dnsPort`（监听端口）。

认证挑战支持文本验证码与图片验证码；需要点击图片或外部登录的挑战明确返回不支持，由调用方提示处理。

`challengeKind: certificate` 表示系统验证未通过，`certificateSHA256` 提供探测到的 leaf SHA-256 指纹，消息只解释验证原因，由界面统一展示指纹。只有 `answer: trust` 才批准该精确证书；拒绝或关闭连接会取消。本次实际使用的指纹也会随 `ready` 返回，便于界面按连接地址保存已批准指纹。探测和批准完成前不发送登录 HTTP 请求或凭据。

厂商客户端支持首选 DNS 模式；现有证据不足以解释 `filter=(null)` 和 `DnsRuleExceptions` 的具体语义，本实现不宣称精确复刻厂商策略。

完整公开分发应同时提供本目录中的修改源码、构建说明和上游 AGPL-3.0 许可证。
