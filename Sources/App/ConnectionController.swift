import AppKit
import Foundation
import Network
import SwiftUI

/// Owns the user's connection intent and presents the helper's actual execution state.
@MainActor
final class ConnectionController: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var snapshot = ConnectionSnapshot(state: .disconnected, sessionID: nil, message: nil, challenge: nil)
    @Published private(set) var activeProfile: ConnectionProfile?
    @Published var errorMessage: String?
    @Published var editorError: String?
    @Published var showingEditor = false
    @Published var editingProfile: ConnectionProfile?
    @Published var isPerformingCommand = false

    private let client = HelperClient()
    private var store: ProfileStore?
    private var desiredRequest: ConnectionRequest?
    private var saveOnSuccess = false
    private var retryTask: Task<Void, Never>?
    private var retryCount = 0
    private let maxRetries = 4
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "miniEasyConnect.network")
    private var networkAvailable = true
    private var observedNetwork = false
    private var networkSignature = ""
    private var notifications: [NSObjectProtocol] = []
    private var stoppedByUser = true

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
        isPerformingCommand || [.connecting, .awaitingAuthorization, .awaitingChallenge, .reconnecting, .disconnecting].contains(snapshot.state)
    }

    var hasConnection: Bool {
        [.connecting, .awaitingChallenge, .connected, .reconnecting, .disconnecting].contains(snapshot.state)
    }

    var stateTitle: String {
        switch snapshot.state {
        case .disconnected: return "准备连接"
        case .awaitingAuthorization: return "需要系统授权"
        case .connecting: return "正在连接"
        case .awaitingChallenge: return "需要完成验证"
        case .connected: return "已连接"
        case .reconnecting: return "正在恢复连接"
        case .disconnecting: return "正在断开"
        case .failed: return "连接未完成"
        }
    }

    func newConnection() {
        editorError = nil
        editingProfile = nil
        showingEditor = true
    }

    func edit(_ profile: ConnectionProfile) {
        editorError = nil
        editingProfile = profile
        showingEditor = true
    }

    func savedPassword(for profile: ConnectionProfile) throws -> String { try requiredStore().password(for: profile) }

    func connect(address: String, username: String, password: String, replacing profile: ConnectionProfile?) {
        do {
            guard !password.isEmpty else { throw ProfileStoreError.missingPassword }
            let record = try requiredStore().profile(address: address, username: username, replacing: profile)
            showingEditor = false
            begin(ConnectionRequest(profile: record, password: password), save: true)
        } catch { editorError = error.localizedDescription }
    }

    func connect(_ profile: ConnectionProfile) {
        do {
            let password = try requiredStore().password(for: profile)
            begin(ConnectionRequest(profile: profile, password: password), save: false)
        } catch {
            errorMessage = error.localizedDescription
            edit(profile)
        }
    }

    func delete(_ profile: ConnectionProfile) {
        guard activeProfile?.id != profile.id || !hasConnection else {
            errorMessage = "请先断开当前连接，再删除记录。"
            return
        }
        do {
            try requiredStore().delete(profile)
            profiles = try requiredStore().load()
        } catch { errorMessage = error.localizedDescription }
    }

    func retry() {
        if let desiredRequest { begin(desiredRequest, save: saveOnSuccess) }
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
        desiredRequest = nil
        saveOnSuccess = false
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        perform(HelperCommand(kind: "disconnect", request: nil, challengeID: nil, answer: nil)) { response in
            completion?(response.ok && response.snapshot.state == .disconnected)
        }
    }

    func prepareToQuit(_ completion: @escaping (Bool) -> Void) {
        retryTask?.cancel()
        stoppedByUser = true
        let noServiceStarted = snapshot.state == .failed && !client.hasServiceConnection
        if ([.disconnected, .awaitingAuthorization].contains(snapshot.state) || noServiceStarted) && !isPerformingCommand {
            desiredRequest = nil
            client.invalidate()
            completion(true)
        } else {
            disconnect { [weak self] success in
                if success { self?.client.invalidate() }
                completion(success)
            }
        }
    }

    private func begin(_ request: ConnectionRequest, save: Bool) {
        guard !isPerformingCommand else { return }
        errorMessage = nil
        stoppedByUser = false
        retryTask?.cancel()
        retryTask = nil
        retryCount = 0
        if hasConnection {
            perform(HelperCommand(kind: "disconnect", request: nil, challengeID: nil, answer: nil)) { [weak self] response in
                guard let self, response.ok, response.snapshot.state == .disconnected else { return }
                self.start(request, save: save)
            }
        } else { start(request, save: save) }
    }

    private func start(_ request: ConnectionRequest, save: Bool) {
        let request = requestWithTrustedCertificate(request)
        desiredRequest = request
        activeProfile = request.profile
        saveOnSuccess = save
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

    private func receive(_ state: ConnectionSnapshot) {
        snapshot = state
        if state.state == .connected {
            retryTask?.cancel()
            retryTask = nil
            retryCount = 0
            if saveOnSuccess, let request = desiredRequest {
                saveOnSuccess = false
                do {
                    let saved = try requiredStore().save(request.profile, password: request.password)
                    profiles = try requiredStore().load()
                    activeProfile = saved
                    desiredRequest = ConnectionRequest(profile: saved, password: request.password,
                        trustedCertificateSHA256: request.trustedCertificateSHA256)
                } catch ProfileStoreError.cleanupFailed {
                    do { profiles = try requiredStore().load() }
                    catch { errorMessage = error.localizedDescription; return }
                    errorMessage = ProfileStoreError.cleanupFailed.localizedDescription
                } catch { errorMessage = "连接已建立，但记录未保存成功：" + error.localizedDescription }
            }
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
