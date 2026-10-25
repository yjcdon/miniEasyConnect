import Foundation
import Darwin

private struct CoreConfiguration: Encodable {
    let serverHost: String
    let serverPort: Int
    let username: String
    let password: String
    let trustedCertificateSHA256: String?
}

private struct CoreCommand: Encodable {
    let version = 1
    let kind: String
    let sessionID: String
    var config: CoreConfiguration?
    var challengeID: String?
    var answer: String?
}

private struct CoreEvent: Decodable {
    let version: Int
    let kind: String
    let sessionID: String
    let phase: String?
    let code: String?
    let message: String?
    let interfaceName: String?
    let dnsAddress: String?
    let routes: [String]?
    let challengeID: String?
    let challengeKind: String?
    let imageBase64: String?
    let certificateSHA256: String?
}

/// Owns the sole active core process and coordinates cleanup independently from the user interface.
final class CoreSupervisor {
    private let queue = DispatchQueue(label: "miniEasyConnect.helper.session")
    private var recovery: NetworkRecovery?
    private let coreURL: URL
    private var snapshot = ConnectionSnapshot(state: .disconnected)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var outputSource: DispatchSourceRead?
    private var childExited = false
    private var stdoutEOF = false
    private var outputDrainDeadline: DispatchWorkItem?
    private var buffer = Data()
    private var owner: UUID?
    private var observers: [UUID: HelperObserver] = [:]
    private var pendingFailure: String?
    private var pendingRetryable = false
    private var stopReplies: [(Data) -> Void] = []
    private var connectDeadline: DispatchWorkItem?
    private var clients: Set<UUID> = []
    private var idleExit: DispatchWorkItem?

    init(coreURL: URL) {
        self.coreURL = coreURL
        do {
            recovery = try NetworkRecovery()
        } catch {
            snapshot = ConnectionSnapshot(state: .failed, message: error.localizedDescription)
        }
        if let recovery {
            do { try recovery.restore() }
            catch { snapshot = ConnectionSnapshot(state: .failed, message: error.localizedDescription) }
        }
    }

    func attached(client: UUID) {
        queue.async {
            self.idleExit?.cancel()
            self.clients.insert(client)
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        queue.async {
            self.stopReplies.append { _ in completion() }
            self.stop(failure: nil)
        }
    }

    func perform(_ data: Data, client: UUID, reply: @escaping (Data) -> Void) {
        queue.async {
            do {
                let command = try JSONDecoder().decode(HelperCommand.self, from: data)
                if let owner = self.owner, owner != client {
                    throw HelperFailure.operation("另一个窗口正在管理连接。")
                }
                switch command.kind {
                case "status": self.respond(reply)
                case "connect":
                    guard let request = command.request else {
                        throw HelperFailure.invalidRequest("缺少连接信息。")
                    }
                    try self.start(request, owner: client)
                    self.respond(reply)
                case "disconnect":
                    self.stopReplies.append(reply)
                    self.stop(failure: nil)
                case "answer":
                    guard let sessionID = self.snapshot.sessionID,
                          let challengeID = command.challengeID,
                          challengeID == self.snapshot.challenge?.id,
                          let answer = command.answer, !answer.isEmpty else {
                        throw HelperFailure.invalidRequest("验证信息已失效或未填写。")
                    }
                    try self.write(CoreCommand(kind: "answer", sessionID: sessionID,
                                               challengeID: challengeID, answer: answer))
                    self.update(ConnectionSnapshot(state: .connecting, sessionID: sessionID))
                    self.scheduleConnectTimeout(sessionID: sessionID)
                    self.respond(reply)
                default: throw HelperFailure.invalidRequest("不支持的操作。")
                }
            } catch {
                self.respond(reply, error: error.localizedDescription)
            }
        }
    }

    func subscribe(_ observer: HelperObserver, client: UUID, reply: @escaping (Data) -> Void) {
        queue.async {
            self.observers[client] = observer
            self.respond(reply)
        }
    }

    /// Loss of the owning XPC connection means the UI exited or crashed, so the tunnel must be released.
    func disconnected(client: UUID) {
        queue.async {
            self.observers.removeValue(forKey: client)
            self.clients.remove(client)
            if self.owner == client { self.stop(failure: nil) }
            else { self.scheduleIdleExit() }
        }
    }

    private func start(_ request: ConnectionRequest, owner: UUID) throws {
        guard process == nil else { throw HelperFailure.operation("请先结束当前连接。") }
        if recovery == nil { recovery = try NetworkRecovery() }
        let recovery = recovery!
        let profile = request.profile
        guard !profile.serverHost.isEmpty, (1...65535).contains(profile.serverPort),
              !profile.username.isEmpty, !request.password.isEmpty else {
            throw HelperFailure.invalidRequest("请填写完整的地址、账号和密码。")
        }
        try HelperIdentity.validateCore(at: coreURL)
        let sessionID = UUID().uuidString
        try recovery.begin(sessionID: sessionID)

        let child = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        child.executableURL = coreURL
        child.arguments = []
        child.standardInput = inputPipe
        child.standardOutput = outputPipe
        child.standardError = FileHandle.nullDevice
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        child.terminationHandler = { [weak self] child in
            self?.queue.async { self?.terminated(child) }
        }
        process = child
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        self.owner = owner
        pendingFailure = nil
        pendingRetryable = false
        childExited = false
        stdoutEOF = false
        buffer.removeAll(keepingCapacity: false)
        update(ConnectionSnapshot(state: .connecting, sessionID: sessionID))
        do {
            try monitorOutput(outputPipe.fileHandleForReading, sessionID: sessionID)
            try child.run()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try write(CoreCommand(kind: "start", sessionID: sessionID,
                                  config: CoreConfiguration(serverHost: profile.serverHost,
                                                            serverPort: profile.serverPort,
                                                            username: profile.username,
                                                            password: request.password,
                                                            trustedCertificateSHA256: request.trustedCertificateSHA256)))
            scheduleConnectTimeout(sessionID: sessionID)
        } catch {
            pendingFailure = "无法启动 VPN 核心。"
            if child.isRunning {
                stop(failure: pendingFailure)
            } else {
                try? input?.close()
                outputSource?.cancel()
                outputSource = nil
                process = nil
                input = nil
                output = nil
                self.owner = nil
                do { try recovery.restore() }
                catch { pendingFailure = error.localizedDescription }
                update(ConnectionSnapshot(state: .failed, message: pendingFailure))
            }
            throw HelperFailure.operation(pendingFailure ?? "无法启动 VPN 核心。")
        }
    }

    /// Reads stdout on the same serial queue as process exit, so the final failure event cannot be discarded.
    private func monitorOutput(_ handle: FileHandle, sessionID: String) throws {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HelperFailure.operation("无法建立 VPN 核心事件通道。")
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readOutput(sessionID: sessionID) }
        source.setCancelHandler { try? handle.close() }
        outputSource = source
        source.resume()
    }

    private func readOutput(sessionID: String) {
        guard snapshot.sessionID == sessionID, !stdoutEOF, let output else { return }
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(output.fileDescriptor, bytes.baseAddress!, bytes.count)
            }
            if count > 0 {
                received(Data(chunk.prefix(count)), sessionID: sessionID)
            } else if count == 0 {
                finishedOutput(sessionID: sessionID)
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                stop(failure: "VPN 核心事件通道读取失败。")
                finishedOutput(sessionID: sessionID)
                return
            }
        }
    }

    private func finishedOutput(sessionID: String) {
        guard snapshot.sessionID == sessionID, !stdoutEOF else { return }
        if !buffer.isEmpty {
            received(Data([10]), sessionID: sessionID)
        }
        stdoutEOF = true
        outputSource?.cancel()
        outputSource = nil
        output = nil
        if !childExited && snapshot.state != .disconnecting {
            stop(failure: "VPN 核心事件通道意外关闭。", retryable: true)
        }
        finishExitedProcess()
    }

    private func received(_ data: Data, sessionID: String) {
        guard sessionID == snapshot.sessionID, process != nil else { return }
        guard !data.isEmpty else { return }
        buffer.append(data)
        guard buffer.count <= 4 * 1024 * 1024 else {
            stop(failure: "核心返回的数据超过允许范围。")
            return
        }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            do {
                let event = try JSONDecoder().decode(CoreEvent.self, from: line)
                guard event.version == 1, event.sessionID == sessionID else {
                    throw HelperFailure.operation("VPN 核心通信版本不匹配。")
                }
                try handle(event)
            } catch {
                stop(failure: error.localizedDescription)
                return
            }
        }
    }

    private func handle(_ event: CoreEvent) throws {
        guard snapshot.state != .disconnecting else { return }
        switch event.kind {
        case "phase":
            if let interfaceName = event.interfaceName, let routes = event.routes {
                try recovery!.prepare(interfaceName: interfaceName, routes: routes)
                try write(CoreCommand(kind: "configure", sessionID: event.sessionID))
            }
        case "challenge":
            guard let id = event.challengeID, let kind = event.challengeKind else {
                throw HelperFailure.operation("核心未提供完整验证信息。")
            }
            connectDeadline?.cancel()
            update(ConnectionSnapshot(state: .awaitingChallenge, sessionID: event.sessionID,
                                      challenge: AuthChallenge(id: id, kind: kind,
                                                               message: event.message, imageBase64: event.imageBase64,
                                                               certificateSHA256: event.certificateSHA256)))
        case "ready":
            guard let address = event.dnsAddress else {
                throw HelperFailure.operation("核心未提供 DNS 配置。")
            }
            try recovery!.applyDNS(address: address)
            connectDeadline?.cancel()
            update(ConnectionSnapshot(state: .connected, sessionID: event.sessionID))
        case "failed": stop(failure: safeMessage(code: event.code), retryable: event.code == "connectionFailed")
        case "stopped":
            if snapshot.state != .disconnecting { stop(failure: "VPN 连接已结束。") }
        default: throw HelperFailure.operation("核心返回了无法识别的事件。")
        }
    }

    /// DNS is withdrawn first; the child receives a graceful stop and a bounded termination deadline.
    private func stop(failure: String?, retryable: Bool = false) {
        connectDeadline?.cancel()
        if let failure {
            pendingFailure = failure
            pendingRetryable = retryable
        }
        guard let process else {
            completeCleanup()
            return
        }
        if snapshot.state == .disconnecting { return }
        update(ConnectionSnapshot(state: .disconnecting, sessionID: snapshot.sessionID))
        do { try recovery?.restoreDNS() }
        catch {
            pendingFailure = error.localizedDescription
            pendingRetryable = false
        }
        do {
            if let sessionID = snapshot.sessionID { try write(CoreCommand(kind: "stop", sessionID: sessionID)) }
        } catch {
            if process.isRunning { process.terminate() }
        }
        let pid = process.processIdentifier
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak process] in
            guard let self, let process, self.process === process, process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private func terminated(_ child: Process) {
        guard process === child else { return }
        connectDeadline?.cancel()
        childExited = true
        try? input?.close()
        input = nil
        if let sessionID = snapshot.sessionID { readOutput(sessionID: sessionID) }
        finishExitedProcess()
        // A descendant retaining stdout must not prevent recovery after the core itself has exited.
        if process === child, !stdoutEOF, let sessionID = snapshot.sessionID {
            let deadline = DispatchWorkItem { [weak self] in
                guard let self, self.process === child, self.childExited, !self.stdoutEOF else { return }
                self.readOutput(sessionID: sessionID)
                self.finishedOutput(sessionID: sessionID)
            }
            outputDrainDeadline = deadline
            queue.asyncAfter(deadline: .now() + 1, execute: deadline)
        }
    }

    private func finishExitedProcess() {
        guard childExited, stdoutEOF, process != nil else { return }
        outputDrainDeadline?.cancel()
        outputDrainDeadline = nil
        process = nil
        if snapshot.state != .disconnecting && pendingFailure == nil {
            pendingFailure = "VPN 核心意外退出，请重新连接。"
            pendingRetryable = true
        }
        completeCleanup()
    }

    private func completeCleanup() {
        do {
            if recovery == nil { recovery = try NetworkRecovery() }
            try recovery!.restore()
        } catch {
            pendingFailure = error.localizedDescription
            pendingRetryable = false
        }
        owner = nil
        buffer.removeAll(keepingCapacity: false)
        update(ConnectionSnapshot(state: pendingFailure == nil ? .disconnected : .failed,
                                  message: pendingFailure, retryable: pendingRetryable))
        let replies = stopReplies
        stopReplies.removeAll()
        for reply in replies { respond(reply, error: pendingFailure) }
        pendingFailure = nil
        pendingRetryable = false
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        guard clients.isEmpty, process == nil else { return }
        idleExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.clients.isEmpty, self.process == nil else { return }
            exit(0)
        }
        idleExit = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func scheduleConnectTimeout(sessionID: String) {
        connectDeadline?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.snapshot.sessionID == sessionID,
                  self.snapshot.state == .connecting else { return }
            self.stop(failure: "连接超时，请检查网络后重试。", retryable: true)
        }
        connectDeadline = deadline
        queue.asyncAfter(deadline: .now() + 60, execute: deadline)
    }

    private func write(_ command: CoreCommand) throws {
        guard let input else { throw HelperFailure.operation("VPN 核心尚未启动。") }
        var data = try JSONEncoder().encode(command)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func update(_ value: ConnectionSnapshot) {
        snapshot = value
        let data = encode(value)
        for observer in observers.values { observer.changed(data) }
    }

    private func respond(_ reply: (Data) -> Void, error: String? = nil) {
        reply(encode(HelperResponse(ok: error == nil, snapshot: snapshot, message: error)))
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        // These local value types contain no fallible custom encoders.
        return try! JSONEncoder().encode(value)
    }

    private func safeMessage(code: String?) -> String {
        switch code {
        case "authenticationFailed": return "账号、密码或验证信息未通过，请检查后重试。"
        case "serverCertificate": return "无法验证 VPN 服务端证书，请检查系统信任设置。"
        case "dnsUnavailable": return "VPN DNS 初始化失败，请检查端口占用和网络配置。"
        case "resourcesUnavailable": return "服务端未提供可用的内网访问资源。"
        case "routeFailed": return "VPN 路由配置失败，请断开其他 VPN 后重试。"
        case "unsupportedMode": return "此服务端连接模式暂不支持 TUN。"
        case "authorizationRequired": return "VPN 核心未获得系统网络操作权限。"
        case "invalidConfiguration": return "连接配置无效，请检查地址和账号。"
        case "unsupportedServer": return "该地址未返回受支持的 EasyConnect 登录信息，请检查 VPN 地址。"
        default: return "VPN 连接失败，请检查地址、网络或认证信息后重试。"
        }
    }
}
