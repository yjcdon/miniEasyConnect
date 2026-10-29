import Foundation
import SystemConfiguration

enum HelperFailure: LocalizedError {
    case invalidRequest(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .operation(let message): return message
        }
    }
}

private struct NetworkJournal: Codable {
    var active: Bool
    var sessionID: String
    var serviceID: String?
    var originalDNS: Data?
    var appliedDNS: Data?
    var vpnDNSKey: String?
    var interfaceName: String?
    var routes: [String]

    private enum CodingKeys: String, CodingKey {
        case active, sessionID, serviceID, originalDNS, appliedDNS, interfaceName, routes
        // Keep the existing journal key so unfinished sessions remain recoverable.
        case vpnDNSKey = "splitDNSKey"
    }
}

/// Owns the temporary VPN DNS resolver and persists enough state to clean up a crashed tunnel.
final class NetworkRecovery {
    private let journalURL: URL
    private var journal: NetworkJournal?
    private var dnsStore: SCDynamicStore?

    init() throws {
        let directory = URL(fileURLWithPath: "/Library/Application Support/miniEasyConnect", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        journalURL = directory.appendingPathComponent("network-recovery.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(NetworkJournal.self, from: Data(contentsOf: journalURL))
        }
    }

    /// Starts a recovery journal without changing the current network service or its DNS settings.
    func begin(sessionID: String) throws {
        try restore()
        guard UUID(uuidString: sessionID) != nil else {
            throw HelperFailure.invalidRequest("网络会话标识无效。")
        }
        journal = NetworkJournal(active: true, sessionID: sessionID, serviceID: nil,
                                 originalDNS: nil, appliedDNS: nil, vpnDNSKey: nil,
                                 interfaceName: nil, routes: [])
        try save()
    }

    /// Persists the tunnel's planned routes before the core is allowed to install them.
    func prepare(interfaceName: String, routes: [String]) throws {
        guard interfaceName.range(of: "^utun[0-9]+$", options: .regularExpression) != nil else {
            throw HelperFailure.invalidRequest("核心返回了无效的虚拟网卡。")
        }
        guard journal?.active == true else {
            throw HelperFailure.operation("网络恢复记录尚未建立。")
        }
        journal!.interfaceName = interfaceName
        journal!.routes = routes
        try save()
    }

    /// Gives VPN DNS priority for all domains once its loopback listener is ready, without changing service preferences.
    func applyVPNDNS(address: String, port: Int) throws {
        guard address == "127.0.0.1", (1024...65535).contains(port) else {
            throw HelperFailure.invalidRequest("核心返回了无效的 VPN DNS 配置。")
        }
        guard let record = journal, record.active, record.vpnDNSKey == nil else {
            throw HelperFailure.operation("网络恢复记录尚未建立或 DNS 已配置。")
        }
        let store = try makeDNSStore()
        let key = resolverKey(sessionID: record.sessionID)
        let configuration: [String: Any] = [
            kSCPropNetDNSServerAddresses as String: [address],
            kSCPropNetDNSServerPort as String: port,
            kSCPropNetDNSSupplementalMatchDomains as String: [""],
            "SupplementalMatchDomainsNoSearch": 1
        ]
        // Persist ownership before publishing, and retain the store for the lifetime of the resolver.
        journal!.vpnDNSKey = key
        try save()
        dnsStore = store
        guard SCDynamicStoreAddTemporaryValue(store, key as CFString, configuration as CFDictionary) else {
            throw HelperFailure.operation("无法建立 VPN DNS 优先配置。")
        }
    }

    /// Withdraws this session's resolver before core shutdown; also recovers legacy network-service DNS journals.
    func restoreDNS() throws {
        guard let record = journal, record.active else { return }
        if let key = record.vpnDNSKey {
            guard UUID(uuidString: record.sessionID) != nil,
                  key == resolverKey(sessionID: record.sessionID) else {
                throw HelperFailure.operation("网络恢复记录中的 DNS 会话无效。")
            }
            let store = try dnsStore ?? makeDNSStore()
            guard SCDynamicStoreRemoveValue(store, key as CFString) || SCError() == kSCStatusNoKey else {
                throw HelperFailure.operation("VPN DNS 优先配置未能清理，请重新启动应用恢复网络。")
            }
            journal!.vpnDNSKey = nil
            try save()
            dnsStore = nil
        }
        guard let applied = try decodeDictionary(record.appliedDNS) else { return }
        guard let serviceID = record.serviceID else {
            throw HelperFailure.operation("旧网络恢复记录缺少网络服务。")
        }
        let preferences = try makePreferences()
        try lock(preferences)
        defer { SCPreferencesUnlock(preferences) }
        let dns = try dnsProtocol(preferences, serviceID: serviceID)
        let current = SCNetworkProtocolGetConfiguration(dns) as? [String: Any]
        let original = try decodeDictionary(record.originalDNS)
        let key = kSCPropNetDNSServerAddresses as String
        if (current?[key] as? [String]) == (applied[key] as? [String]) {
            var restored = current ?? [:]
            restored[key] = original?[key]
            try setDNS(restored.isEmpty && original == nil ? nil : restored,
                       protocol: dns, preferences: preferences)
        }
        // External changes to server addresses now own that field; preserve them and release our journal.
        journal!.appliedDNS = nil
        try save()
    }

    /// Removes only routes still owned by this session's virtual interface, then marks its journal complete.
    func finish() throws {
        guard let record = journal, record.active else { return }
        try restoreDNS()
        if let interfaceName = record.interfaceName {
            for route in record.routes {
                let query = try command("/sbin/route", ["-n", "get", "-net", route])
                if query.status == 0 && query.output.split(separator: "\n").contains(where: {
                    $0.trimmingCharacters(in: .whitespaces) == "interface: \(interfaceName)"
                }) {
                    let deletion = try command("/sbin/route", ["-n", "delete", "-net", route, "-interface", interfaceName])
                    guard deletion.status == 0 else {
                        throw HelperFailure.operation("本次 VPN 路由未能清理，请重新启动应用恢复网络。")
                    }
                }
            }
        }
        journal!.active = false
        journal!.routes = []
        journal!.interfaceName = nil
        try save()
    }

    func restore() throws {
        try restoreDNS()
        try finish()
    }

    private func resolverKey(sessionID: String) -> String {
        "State:/Network/Service/miniEasyConnect-\(sessionID)/DNS"
    }

    private func makeDNSStore() throws -> SCDynamicStore {
        guard let store = SCDynamicStoreCreate(nil, "miniEasyConnect.vpnDNS" as CFString, nil, nil) else {
            throw HelperFailure.operation("无法访问系统 VPN DNS 配置。")
        }
        return store
    }

    private func makePreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, "miniEasyConnect" as CFString, nil) else {
            throw HelperFailure.operation("无法读取系统网络配置。")
        }
        return preferences
    }

    private func dnsProtocol(_ preferences: SCPreferences, serviceID: String) throws -> SCNetworkProtocol {
        guard let service = SCNetworkServiceCopy(preferences, serviceID as CFString),
              let dns = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeDNS) else {
            throw HelperFailure.operation("当前网络服务的 DNS 配置不可用。")
        }
        return dns
    }

    private func setDNS(_ configuration: [String: Any]?, protocol dns: SCNetworkProtocol,
                        preferences: SCPreferences) throws {
        guard SCNetworkProtocolSetConfiguration(dns, configuration as CFDictionary?),
              SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw HelperFailure.operation("无法更新系统 DNS 配置。")
        }
    }

    private func lock(_ preferences: SCPreferences) throws {
        guard SCPreferencesLock(preferences, false) else {
            throw HelperFailure.operation("无法锁定系统网络配置。")
        }
        SCPreferencesSynchronize(preferences)
    }

    private func save() throws {
        // Recreate our journal directory if a cleanup tool removed it during an active session.
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func decodeDictionary(_ data: Data?) throws -> [String: Any]? {
        guard let data else { return nil }
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw HelperFailure.operation("网络恢复记录格式错误。")
        }
        return dictionary
    }

    private func command(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
