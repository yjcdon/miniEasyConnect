import Foundation
import Security
import SystemConfiguration
import Darwin

enum HelperIdentity {
    static func requirement(identifier: String) throws -> String {
        var ownCode: SecCode?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode else {
            throw HelperFailure.operation("无法读取辅助服务签名。")
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode else {
            throw HelperFailure.operation("无法读取辅助服务签名。")
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else {
            throw HelperFailure.operation("辅助服务缺少有效的开发者签名。")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    static func validateCore(at url: URL) throws {
        let expression = try requirement(identifier: AppIdentity.bundleID + ".core")
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code, let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw HelperFailure.operation("VPN 核心签名无效，请重新安装应用。")
        }
    }

    static func accept(_ connection: NSXPCConnection) -> Bool {
        var consoleUID: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil,
              consoleUID != 0, connection.effectiveUserIdentifier == consoleUID,
              let expression = try? requirement(identifier: AppIdentity.bundleID) else { return false }
        var requirement: SecRequirement?
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code, let requirement,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        connection.setCodeSigningRequirement(expression)
        return true
    }
}

private final class HelperEndpoint: NSObject, HelperProtocol {
    let id = UUID()
    private let supervisor: CoreSupervisor

    init(supervisor: CoreSupervisor) { self.supervisor = supervisor }

    func perform(_ command: Data, withReply reply: @escaping (Data) -> Void) {
        supervisor.perform(command, client: id, reply: reply)
    }

    func subscribe(_ observer: HelperObserver, withReply reply: @escaping (Data) -> Void) {
        supervisor.subscribe(observer, client: id, reply: reply)
    }
}

private final class HelperListener: NSObject, NSXPCListenerDelegate {
    private let supervisor: CoreSupervisor

    init(supervisor: CoreSupervisor) { self.supervisor = supervisor }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard HelperIdentity.accept(connection) else { return false }
        let endpoint = HelperEndpoint(supervisor: supervisor)
        let interface = NSXPCInterface(with: HelperProtocol.self)
        interface.setInterface(NSXPCInterface(with: HelperObserver.self), for: #selector(HelperProtocol.subscribe(_:withReply:)),
                               argumentIndex: 0, ofReply: false)
        connection.exportedInterface = interface
        connection.exportedObject = endpoint
        supervisor.attached(client: endpoint.id)
        connection.invalidationHandler = { [supervisor] in supervisor.disconnected(client: endpoint.id) }
        connection.interruptionHandler = { [supervisor] in supervisor.disconnected(client: endpoint.id) }
        connection.resume()
        return true
    }
}

@main
enum HelperMain {
    static func main() {
        guard geteuid() == 0 else {
            fputs("miniEasyConnectHelper must be started by its authorized launch daemon.\n", stderr)
            exit(1)
        }
        signal(SIGPIPE, SIG_IGN)
        let executable = executableURL()
        let core = executable.deletingLastPathComponent().appendingPathComponent(AppIdentity.coreExecutableName)
        let supervisor = CoreSupervisor(coreURL: core)
        let delegate = HelperListener(supervisor: supervisor)
        let listener = NSXPCListener(machServiceName: AppIdentity.machService)
        listener.delegate = delegate
        listener.resume()
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { supervisor.shutdown { exit(0) } }
        termination.resume()
        withExtendedLifetime((delegate, termination)) { RunLoop.current.run() }
    }

    /// Resolves the running binary independently of launchd's relative BundleProgram argument.
    private static func executableURL() -> URL {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else {
            fputs("Unable to resolve the helper executable path.\n", stderr)
            exit(1)
        }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
    }
}
