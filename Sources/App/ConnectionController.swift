import AppKit
import Foundation
import Network
import SwiftUI

/// Owns the user's connection intent and presents the helper's actual execution state.
@MainActor
final class ConnectionController: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var snapshot = ConnectionSnapshot(state: .disconnected, sessionID: nil, message: nil, challenge: nil) {
        didSet { recordConnectionStability(previous: oldValue) }
    }
    @Published private(set) var activeProfile: ConnectionProfile?
    @Published private(set) var switchingProfile: ConnectionProfile?
    @Published var errorMessage: String?
    @Published var editorError: String?
    @Published var showingEditor = false
    @Published var editingProfile: ConnectionProfile?
    @Published var noteEditingProfile: ConnectionProfile?
    @Published var noteEditorError: String?
    @Published var isPerformingCommand = false
    @Published private(set) var isDisablingHelper = false

    private let client = HelperClient()
    private var store: ProfileStore?
    private var desiredRequest: ConnectionRequest?
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private let maxRetries = 4
    private var connectedSince: TimeInterval?
    private let stableConnectionDuration: TimeInterval = 30
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "miniEasyConnect.network")
    private var networkAvailable = true
    private var observedNetwork = false
    private var networkSignature = ""
    private var notifications: [NSObjectProtocol] = []
    private var stoppedByUser = true
    private let lastUsedProfileKey = "lastUsedConnectionProfileID"

    init() {
        do {
            let store = try ProfileStore()
            self.store = store
            profiles = try store.load()
        } catch { errorMessage = error.localizedDescription }
        client.onSnapshot = { [weak self] state in self?.receive(state) }
        client.onInterruption = { [weak self] in self?.serviceInterrupted() }
        monitor.pathUpdateHandler = { [weak self] path in
            // Ignore virtual interfaces so creating our own TUN cannot trigger a reconnect loop.
            let signature = path.availableInterfaces.filter {
                [.wifi, .wiredEthernet, .cellular].contains($0.type) && path.usesInterfaceType($0.type)
            }.map { $0.name }.sorted().joined(separator: ",")
            DispatchQueue.main.async { self?.networkChanged(available: path.status == .satisfied, signature: signature) }
        }
        monitor.start(queue: monitorQueue)
        let center = NSWorkspace.shared.notificationCenter
        notifications.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterWake() }
        })
    }

    deinit {
        monitor.cancel()
        retryTask?.cancel()
        for token in notifications { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        client.invalidate()
    }

    var isBusy: Bool {
        isPerformingCommand || isDisablingHelper || [.connecting, .awaitingAuthorization, .awaitingChallenge, .reconnecting, .disconnecting].contains(snapshot.state)
    }

    var hasConnection: Bool {
        [.connecting, .awaitingChallenge, .connected, .reconnecting, .disconnecting].contains(snapshot.state)
    }

    var isEditing: Bool {
        showingEditor || noteEditingProfile != nil || snapshot.state == .awaitingChallenge
    }

    var canStartConnection: Bool { !isBusy && !isEditing }
    var canConnectLastUsed: Bool { canStartConnection && !hasConnection }
    var canDisconnect: Bool { hasConnection && !isPerformingCommand && !isDisablingHelper && snapshot.state != .disconnecting }

    var stateTitle: String {
        switch snapshot.state {
        case .disconnected: return "未连接"
        case .awaitingAuthorization: return "需要系统授权"
        case .connecting: return "正在连接"
        case .awaitingChallenge: return "需要完成验证"
        case .connected: return "已连接"
        case .reconnecting: return "正在恢复连接"
        case .disconnecting: return "正在断开"
        case .failed: return "连接失败"
        }
    }

    func newConnection() {
        guard canStartConnection else { return }
        editorError = nil
        editingProfile = nil
        showingEditor = true
    }

    var lastUsedProfile: ConnectionProfile? {
        let lastID = UserDefaults.standard.string(forKey: lastUsedProfileKey)
        return profiles.first { $0.id.uuidString == lastID } ?? profiles.first
    }

    /// Reuses the latest connection record across launches, or opens the first-connection form.
    func connectLastUsed() {
        guard canConnectLastUsed else { return }
        if let profile = lastUsedProfile { connect(profile) }
        else { newConnection() }
    }

    func edit(_ profile: ConnectionProfile) {
        editorError = nil
        editingProfile = profile
        showingEditor = true
    }

    func editNote(_ profile: ConnectionProfile) {
        noteEditorError = nil
        noteEditingProfile = profile
    }

    /// Updates the display note locally without re-establishing the current connection.
    func saveNote(_ profile: ConnectionProfile, note: String) {
        do {
            let saved = try requiredStore().updateNote(profile, note: note)
            profiles = try requiredStore().load()
            if var active = activeProfile, active.id == saved.id {
                active.note = saved.note
                activeProfile = active
            }
            if let request = desiredRequest, request.profile.id == saved.id {
                var updatedProfile = request.profile
                updatedProfile.note = saved.note
                desiredRequest = ConnectionRequest(profile: updatedProfile, password: request.password,
                    trustedCertificateSHA256: request.trustedCertificateSHA256)
            }
            noteEditingProfile = nil
        } catch { noteEditorError = error.localizedDescription }
    }

    var canEditCurrentConnection: Bool { desiredRequest != nil || activeProfile != nil }

    func editCurrentConnection() {
        guard let profile = desiredRequest?.profile ?? activeProfile else { return }
        edit(profile)
    }

    /// Reuses the current request in memory; other saved records read their password from Keychain.
    func passwordForEditing(_ profile: ConnectionProfile) throws -> String {
        if let request = desiredRequest, request.profile == profile { return request.password }
        return try requiredStore().password(for: profile)
    }

    /// Saves validated connection details before authorization or any connection attempt.
    func connect(address: String, username: String, password: String, note: String = "", replacing profile: ConnectionProfile?) {
        guard !isPerformingCommand, !isDisablingHelper else { return }
        do {
            guard !password.isEmpty else { throw ProfileStoreError.missingPassword }
            let store = try requiredStore()
            let record = try store.profile(address: address, username: username, note: note, replacing: profile)
            let saved: ConnectionProfile
            var warning: String?
            do { saved = try store.save(record, password: password) }
            catch ProfileStoreError.cleanupFailed(let committed) {
                saved = committed
                warning = ProfileStoreError.cleanupFailed(committed).localizedDescription
            }
            if let index = profiles.firstIndex(where: { $0.id == saved.id }) { profiles[index] = saved }
            else { profiles.append(saved) }
            editingProfile = saved
            let request = ConnectionRequest(profile: saved, password: password)
            desiredRequest = request
            editorError = nil
            showingEditor = false
            begin(request)
            if let warning { errorMessage = warning }
        } catch { editorError = error.localizedDescription }
    }

    func connect(_ profile: ConnectionProfile) {
        guard canStartConnection else { return }
        do {
            let password = try requiredStore().password(for: profile)
            begin(ConnectionRequest(profile: profile, password: password))
        } catch {
            errorMessage = error.localizedDescription
            edit(profile)
        }
    }

    /// Deletes a saved connection and its password only after explicit confirmation.
    func confirmDelete(_ profile: ConnectionProfile) {
        let alert = NSAlert()
        alert.messageText = "删除“\(profile.displayName)”？"
        alert.informativeText = "将删除这条连接记录及保存的密码。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        delete(profile)
    }

    func delete(_ profile: ConnectionProfile) {
        guard activeProfile?.id != profile.id || !hasConnection else {
            errorMessage = "请先断开当前连接，再删除记录。"
            return
        }
        do {
            try requiredStore().delete(profile)
            profiles = try requiredStore().load()
            if UserDefaults.standard.string(forKey: lastUsedProfileKey) == profile.id.uuidString {
                UserDefaults.standard.removeObject(forKey: lastUsedProfileKey)
            }
            if activeProfile?.id == profile.id {
                stoppedByUser = true
                retryTask?.cancel()
                retryTask = nil
                desiredRequest = nil
                activeProfile = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func retry() {
        if let desiredRequest { begin(desiredRequest) }
        else if let activeProfile { connect(activeProfile) }
        else { newConnection() }
    }

    func openAuthorizationSettings() { client.openAuthorizationSettings() }

    func answerChallenge(_ answer: String) {
        guard let challenge = snapshot.challenge, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        perform(HelperCommand(kind: "answer", request: nil, challengeID: challenge.id, answer: answer))
    }

    /// Persists an explicitly approved certificate for this endpoint, never a global TLS bypass.
    func trustCertificate() {
        guard snapshot.state == .awaitingChallenge, !isPerformingCommand,
              let challenge = snapshot.challenge, challenge.kind == "certificate",
              let fingerprint = challenge.certificateSHA256,
              let request = desiredRequest else { return }
        UserDefaults.standard.set(fingerprint, forKey: certificateKey(for: request.profile))
        desiredRequest = ConnectionRequest(profile: request.profile, password: request.password,
            trustedCertificateSHA256: fingerprint)
        answerChallenge("trust")
    }

    /// A deliberate disconnect clears reconnect intent before stopping the actual session.
    func disconnect(completion: ((Bool) -> Void)? = nil) {
        stoppedByUser = true
        switchingProfile = nil
        desiredRequest = nil
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        perform(HelperCommand(kind: "disconnect", request: nil, challengeID: nil, answer: nil)) { [weak self] response in
            let success = response.ok && response.snapshot.state == .disconnected
            if success { self?.client.invalidate() }
            completion?(success)
        }
    }

    func prepareToQuit(_ completion: @escaping (Bool) -> Void) {
        guard !isDisablingHelper else { completion(false); return }
        retryTask?.cancel()
        stoppedByUser = true
        switchingProfile = nil
        let noServiceStarted = snapshot.state == .failed && !client.hasServiceConnection
        if !client.hasServiceConnection && ([.disconnected, .awaitingAuthorization].contains(snapshot.state) || noServiceStarted) && !isPerformingCommand {
            desiredRequest = nil
            client.invalidate()
            completion(true)
        } else { disconnect(completion: completion) }
    }

    /// A deliberate maintenance action; normal disconnect and quit keep the system approval registered.
    func confirmDisableHelper() {
        guard !isPerformingCommand, !isDisablingHelper, snapshot.state != .disconnecting else { return }
        let alert = NSAlert()
        alert.messageText = "停用后台服务？"
        alert.informativeText = "这会断开当前 VPN 并恢复网络设置。再次连接时会重新启用服务，可能需要系统批准。已保存的连接记录会保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "停用后台服务")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !isPerformingCommand, !isDisablingHelper, snapshot.state != .disconnecting else {
            errorMessage = "连接操作正在完成，请稍后重试停用后台服务。"
            return
        }
        disableHelper()
    }

    /// Clears reconnect intent and unregisters only after the helper confirms complete network restoration.
    private func disableHelper() {
        isDisablingHelper = true
        errorMessage = nil
        stoppedByUser = true
        desiredRequest = nil
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        let unregister: (Bool) -> Void = { [weak self] cleaned in
            guard let self else { return }
            guard cleaned else {
                self.isDisablingHelper = false
                self.errorMessage = self.snapshot.message ?? "网络尚未恢复，后台服务未停用。请先重试断开。"
                return
            }
            self.client.unregister { [weak self] result in
                guard let self else { return }
                self.isDisablingHelper = false
                switch result {
                case .success:
                    self.snapshot = ConnectionSnapshot(state: .disconnected, message: "后台服务已停用，下次连接时会重新启用。")
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
            }
        }
        // Even a newly opened window must ask an enabled helper to finish any previous recovery.
        if client.isServiceEnabled || client.hasServiceConnection || hasConnection {
            disconnect(completion: unregister)
        } else {
            unregister(true)
        }
    }

    private func begin(_ request: ConnectionRequest) {
        guard !isPerformingCommand, !isDisablingHelper else { return }
        errorMessage = nil
        stoppedByUser = false
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        connectedSince = nil
        if hasConnection {
            switchingProfile = request.profile
            perform(HelperCommand(kind: "disconnect", request: nil, challengeID: nil, answer: nil)) { [weak self] response in
                guard let self else { return }
                self.switchingProfile = nil
                guard !self.stoppedByUser, response.ok, response.snapshot.state == .disconnected else { return }
                self.start(request)
            }
        } else { start(request) }
    }

    private func start(_ request: ConnectionRequest) {
        switchingProfile = nil
        let request = requestWithTrustedCertificate(request)
        desiredRequest = request
        activeProfile = request.profile
        UserDefaults.standard.set(request.profile.id.uuidString, forKey: lastUsedProfileKey)
        do {
            try client.authorize()
            perform(HelperCommand(kind: "connect", request: request, challengeID: nil, answer: nil))
        } catch HelperClientError.approvalRequired {
            snapshot = ConnectionSnapshot(state: .awaitingAuthorization, sessionID: nil,
                message: HelperClientError.approvalRequired.localizedDescription, challenge: nil)
        } catch {
            stoppedByUser = true
            snapshot = ConnectionSnapshot(state: .failed, sessionID: nil, message: error.localizedDescription, challenge: nil)
        }
    }

    private func perform(_ command: HelperCommand, completion: ((HelperResponse) -> Void)? = nil) {
        isPerformingCommand = true
        client.send(command) { [weak self] result in
            guard let self else { return }
            self.isPerformingCommand = false
            switch result {
            case .success(let response):
                self.receive(response.snapshot)
                if !response.ok && !response.snapshot.retryable {
                    self.errorMessage = response.message ?? response.snapshot.message ?? "操作未完成，请重试。"
                }
                completion?(response)
            case .failure:
                self.receive(ConnectionSnapshot(state: .failed, sessionID: self.snapshot.sessionID,
                    message: "无法连接后台服务，请重试。", challenge: nil, retryable: true))
                if self.stoppedByUser { self.errorMessage = self.snapshot.message }
                completion?(HelperResponse(ok: false, snapshot: self.snapshot, message: self.snapshot.message))
            }
        }
    }

    /// Preserves the retry budget until a connection has remained usable for thirty seconds.
    private func recordConnectionStability(previous: ConnectionSnapshot) {
        if snapshot.state == .connected && previous.state == .connected && snapshot.sessionID == previous.sessionID {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let connectedSince, now - connectedSince >= stableConnectionDuration {
            retryCount = 0
        }
        connectedSince = snapshot.state == .connected ? now : nil
    }

    private func receive(_ state: ConnectionSnapshot) {
        snapshot = state
        if state.state == .connected {
            retryTask?.cancel()
            retryTask = nil
        }
        if state.state == .failed && !stoppedByUser {
            retryTask?.cancel()
            retryTask = nil
            if state.retryable { scheduleReconnect() }
            else { stoppedByUser = true }
        }
    }

    private func serviceInterrupted() {
        guard hasConnection else { return }
        snapshot = ConnectionSnapshot(state: .reconnecting, sessionID: snapshot.sessionID,
            message: "后台服务正在恢复，请稍候。", challenge: nil)
        scheduleReconnect()
    }

    private func networkChanged(available: Bool, signature: String) {
        let wasAvailable = networkAvailable
        let oldSignature = networkSignature
        networkAvailable = available
        networkSignature = signature
        guard observedNetwork else { observedNetwork = true; return }
        guard !stoppedByUser, desiredRequest != nil else { return }
        if !available {
            retryTask?.cancel()
            retryTask = nil
            snapshot = ConnectionSnapshot(state: .reconnecting, sessionID: snapshot.sessionID,
                message: "正在等待网络恢复。", challenge: nil)
        } else if !wasAvailable || signature != oldSignature { scheduleReconnect() }
    }

    private func refreshAfterWake() {
        guard !stoppedByUser, desiredRequest != nil else { return }
        // The process surviving sleep does not prove its TCP/TLS session is still usable.
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard retryTask == nil, !stoppedByUser, networkAvailable, desiredRequest != nil else { return }
        if snapshot.state == .connected {
            snapshot = ConnectionSnapshot(state: .reconnecting, sessionID: snapshot.sessionID,
                message: "正在恢复连接，请稍候。", challenge: nil)
        }
        guard retryCount < maxRetries else {
            stoppedByUser = true
            snapshot = ConnectionSnapshot(state: .failed, sessionID: snapshot.sessionID,
                message: "暂时无法恢复连接，请手动重试。", challenge: nil)
            return
        }
        let delay = UInt64(min(2 << retryCount, 16)) * 1_000_000_000
        retryCount += 1
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !self.stoppedByUser, self.networkAvailable, let request = self.desiredRequest else { return }
            self.retryTask = nil
            self.perform(HelperCommand(kind: "disconnect", request: nil, challengeID: nil, answer: nil)) { [weak self] response in
                guard let self, !self.stoppedByUser else { return }
                guard response.ok, response.snapshot.state == .disconnected else { self.scheduleReconnect(); return }
                do {
                    try self.client.authorize()
                    let updatedRequest = self.requestWithTrustedCertificate(request)
                    self.desiredRequest = updatedRequest
                    self.perform(HelperCommand(kind: "connect", request: updatedRequest, challengeID: nil, answer: nil))
                } catch {
                    self.snapshot = ConnectionSnapshot(state: .failed, sessionID: nil,
                        message: error.localizedDescription, challenge: nil)
                }
            }
        }
    }

    private func requiredStore() throws -> ProfileStore {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        return store
    }

    private func requestWithTrustedCertificate(_ request: ConnectionRequest) -> ConnectionRequest {
        ConnectionRequest(profile: request.profile, password: request.password,
            trustedCertificateSHA256: UserDefaults.standard.string(forKey: certificateKey(for: request.profile)))
    }

    private func certificateKey(for profile: ConnectionProfile) -> String {
        "trustedCertificateSHA256.\(profile.serverHost.lowercased()):\(profile.serverPort)"
    }
}
