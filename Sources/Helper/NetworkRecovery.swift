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
    var serviceID: String
    var originalDNS: Data?
    var appliedDNS: Data?
    var interfaceName: String?
    var routes: [String]
}

/// Keeps the original DNS configuration outside the core process so a crashed tunnel can be cleaned up.
final class NetworkRecovery {
    private let journalURL: URL
    private var journal: NetworkJournal?

    init() throws {
        let directory = URL(fileURLWithPath: "/Library/Application Support/miniEasyConnect", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        journalURL = directory.appendingPathComponent("network-recovery.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(NetworkJournal.self, from: Data(contentsOf: journalURL))
        }
    }

    /// Captures configured DNS, including the distinction between static addresses and automatic configuration.
    func begin(sessionID: String) throws {
        try restore()
        guard let store = SCDynamicStoreCreate(nil, "miniEasyConnect" as CFString, nil, nil),
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let serviceID = state["PrimaryService"] as? String else {
            throw HelperFailure.operation("当前没有可用的网络连接。")
        }
        let preferences = try makePreferences()
        let dns = try dnsProtocol(preferences, serviceID: serviceID)
        let original = SCNetworkProtocolGetConfiguration(dns) as? [String: Any]
        journal = NetworkJournal(active: true, sessionID: sessionID, serviceID: serviceID,
                                 originalDNS: try encodeDictionary(original), appliedDNS: nil,
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

    /// Changes DNS only after the local listener is ready; the applied value is journaled before committing.
    func applyDNS(address: String) throws {
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1, journal?.active == true else {
            throw HelperFailure.invalidRequest("核心返回了无效的 DNS 地址。")
        }
        let preferences = try makePreferences()
        let dns = try dnsProtocol(preferences, serviceID: journal!.serviceID)
        var configuration = try decodeDictionary(journal!.originalDNS) ?? [:]
        configuration[kSCPropNetDNSServerAddresses as String] = [address]
        journal!.appliedDNS = try encodeDictionary(configuration)
        try save()
        try setDNS(configuration, protocol: dns, preferences: preferences)
    }

    /// Restores DNS before the core stops. A configuration changed by another application is preserved.
    func restoreDNS() throws {
        guard let record = journal, record.active, let applied = try decodeDictionary(record.appliedDNS) else { return }
        let preferences = try makePreferences()
        let dns = try dnsProtocol(preferences, serviceID: record.serviceID)
        let current = SCNetworkProtocolGetConfiguration(dns) as? [String: Any]
        let original = try decodeDictionary(record.originalDNS)
        if dictionariesEqual(current, original) {
            journal!.appliedDNS = nil
            try save()
            return
        }
        guard dictionariesEqual(current, applied) else {
            throw HelperFailure.operation("网络设置已被其他程序修改，未覆盖新设置。请检查系统 DNS。")
        }
        try setDNS(original, protocol: dns, preferences: preferences)
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
        guard SCPreferencesLock(preferences, true) else {
            throw HelperFailure.operation("无法锁定系统网络配置。")
        }
        defer { SCPreferencesUnlock(preferences) }
        guard SCNetworkProtocolSetConfiguration(dns, configuration as CFDictionary?),
              SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw HelperFailure.operation("无法更新系统 DNS 配置。")
        }
    }

    private func save() throws {
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    private func encodeDictionary(_ dictionary: [String: Any]?) throws -> Data? {
        guard let dictionary else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    private func decodeDictionary(_ data: Data?) throws -> [String: Any]? {
        guard let data else { return nil }
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw HelperFailure.operation("网络恢复记录格式错误。")
        }
        return dictionary
    }

    private func dictionariesEqual(_ left: [String: Any]?, _ right: [String: Any]?) -> Bool {
        switch (left, right) {
        case (nil, nil): return true
        case (let left?, let right?): return NSDictionary(dictionary: left).isEqual(to: right)
        default: return false
        }
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
