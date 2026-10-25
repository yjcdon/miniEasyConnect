import Foundation
import ServiceManagement

enum HelperClientError: LocalizedError {
    case approvalRequired
    case unavailable
    case rejected(String)
    case registrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .approvalRequired: return "请在系统设置中允许 miniEasyConnect 的后台服务，然后重试连接。"
        case .unavailable: return "后台连接服务不可用，请重试连接。"
        case .rejected(let message): return message
        case .registrationFailed(let cause):
            return "后台服务未能启用（错误 \((cause as NSError).code)）。请确认应用位于“应用程序”文件夹，并检查系统后台服务授权。"
        }
    }
}

/// Uses authenticated XPC for privileged operations; no shell commands or secrets in arguments.
final class HelperClient: NSObject, HelperObserver {
    var onSnapshot: ((ConnectionSnapshot) -> Void)?
    var onInterruption: (() -> Void)?
    private var connection: NSXPCConnection?
    private let service = SMAppService.daemon(plistName: AppIdentity.helperPlistName)

    var hasServiceConnection: Bool { connection != nil }

    func authorize() throws {
        if service.status == .notRegistered || service.status == .notFound {
            do { try service.register() }
            catch {
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    throw HelperClientError.approvalRequired
                }
                throw HelperClientError.registrationFailed(error)
            }
        }
        guard service.status == .enabled else {
            if service.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                throw HelperClientError.approvalRequired
            }
            throw HelperClientError.unavailable
        }
    }

    func openAuthorizationSettings() { SMAppService.openSystemSettingsLoginItems() }

    func invalidate() {
        let previous = connection
        connection = nil
        previous?.invalidationHandler = nil
        previous?.interruptionHandler = nil
        previous?.exportedObject = nil
        previous?.invalidate()
    }

    func send(_ command: HelperCommand, completion: @escaping (Result<HelperResponse, Error>) -> Void) {
        var finished = false
        let finish: (Result<HelperResponse, Error>) -> Void = { result in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(result)
            }
        }
        do {
            let data = try JSONEncoder().encode(command)
            let connection = openConnection()
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(error))
            }) as? HelperProtocol else { throw HelperClientError.unavailable }
            remote.perform(data) { response in
                let result = Result { try JSONDecoder().decode(HelperResponse.self, from: response) }
                finish(result)
            }
        } catch { finish(.failure(error)) }
    }

    func changed(_ snapshot: Data) {
        do {
            let state = try JSONDecoder().decode(ConnectionSnapshot.self, from: snapshot)
            DispatchQueue.main.async { [weak self] in self?.onSnapshot?(state) }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onInterruption?() }
        }
    }

    private func openConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: AppIdentity.machService, options: .privileged)
        let remoteInterface = NSXPCInterface(with: HelperProtocol.self)
        remoteInterface.setInterface(NSXPCInterface(with: HelperObserver.self),
            for: #selector(HelperProtocol.subscribe(_:withReply:)), argumentIndex: 0, ofReply: false)
        connection.remoteObjectInterface = remoteInterface
        connection.exportedInterface = NSXPCInterface(with: HelperObserver.self)
        connection.exportedObject = self
        connection.setCodeSigningRequirement(AppIdentity.signingRequirement(for: AppIdentity.helperID))
        connection.interruptionHandler = { [weak self] in
            DispatchQueue.main.async { self?.onInterruption?() }
        }
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.connection = nil
                self?.onInterruption?()
            }
        }
        connection.resume()
        self.connection = connection
        if let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            DispatchQueue.main.async { self?.onInterruption?() }
        }) as? HelperProtocol {
            remote.subscribe(self) { [weak self] response in
                do {
                    let result = try JSONDecoder().decode(HelperResponse.self, from: response)
                    DispatchQueue.main.async { self?.onSnapshot?(result.snapshot) }
                } catch {
                    DispatchQueue.main.async { self?.onInterruption?() }
                }
            }
        }
        return connection
    }
}
