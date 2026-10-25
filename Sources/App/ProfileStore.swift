import Foundation
import Security

enum ProfileStoreError: LocalizedError {
    case invalidAddress
    case missingUsername
    case missingPassword
    case unsupportedFormat
    case keychain(OSStatus)
    case cleanupFailed(ConnectionProfile)
    case duplicateConnection
    case recordNotFound

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入有效的 VPN 地址，例如 vpn.example.com:443。"
        case .missingUsername: return "请输入账号。"
        case .missingPassword: return "请输入密码。"
        case .unsupportedFormat: return "连接记录格式无法识别，请检查应用版本。"
        case .keychain(let status):
            if status == errSecItemNotFound { return "保存的密码不存在，请重新输入。" }
            if status == errSecInteractionNotAllowed { return "系统钥匙串暂时不可用，请解锁后重试。" }
            return "无法访问系统钥匙串（\(status)）。"
        case .cleanupFailed: return "连接记录和新密码已保存，但旧密码存储项未能清理；不影响使用当前记录。"
        case .duplicateConnection: return "已有相同地址和账号的连接记录，请直接使用已有记录。"
        case .recordNotFound: return "这条连接记录已不存在，请重新选择。"
        }
    }
}

/// Stores connection metadata locally and keeps passwords exclusively in Keychain.
final class ProfileStore {
    private struct Document: Codable {
        let schemaVersion: Int
        var profiles: [ConnectionProfile]
    }

    private let directory: URL
    private let file: URL

    init() throws {
        directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("miniEasyConnect", isDirectory: true)
        file = directory.appendingPathComponent("connections.json")
    }

    func load() throws -> [ConnectionProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.schemaVersion == 1 else { throw ProfileStoreError.unsupportedFormat }
        return document.profiles
    }

    /// Normalizes the address boundary while preserving the account case and secret exactly.
    func profile(address: String, username: String, note: String? = nil, replacing original: ConnectionProfile?) throws -> ConnectionProfile {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = text.contains("://") ? text : "https://" + text
        guard let parts = URLComponents(string: input), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              !(host.contains(where: { $0.isWhitespace })),
              parts.port == nil || (1...65535).contains(parts.port!) else {
            throw ProfileStoreError.invalidAddress
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProfileStoreError.missingUsername
        }
        let profile = ConnectionProfile(id: original?.id ?? UUID(), serverHost: host.lowercased(),
            serverPort: parts.port ?? 443, username: username, credentialRef: original?.credentialRef ?? UUID().uuidString,
            note: normalizedNote(note))
        try validateUniqueEdit(profile, among: load())
        return profile
    }

    func password(for profile: ConnectionProfile) throws -> String {
        var query = credentialQuery(profile.credentialRef)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw ProfileStoreError.keychain(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ProfileStoreError.keychain(errSecDecode)
        }
        return value
    }

    /// Commits new credentials before replacing metadata; rolls back a failed metadata write.
    @discardableResult
    func save(_ profile: ConnectionProfile, password: String) throws -> ConnectionProfile {
        guard !password.isEmpty else { throw ProfileStoreError.missingPassword }
        var profiles = try load()
        try validateUniqueEdit(profile, among: profiles)
        let existing = profiles.first(where: { $0.id == profile.id }) ?? profiles.first(where: {
            $0.serverHost == profile.serverHost && $0.serverPort == profile.serverPort && $0.username == profile.username
        })
        let saved = ConnectionProfile(id: existing?.id ?? profile.id, serverHost: profile.serverHost,
            serverPort: profile.serverPort, username: profile.username, credentialRef: UUID().uuidString,
            note: normalizedNote(profile.note))
        var query = credentialQuery(saved.credentialRef)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrLabel as String] = "miniEasyConnect"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProfileStoreError.keychain(status) }
        if let index = profiles.firstIndex(where: { $0.id == saved.id }) { profiles[index] = saved }
        else { profiles.append(saved) }
        do { try write(profiles) }
        catch {
            SecItemDelete(credentialQuery(saved.credentialRef) as CFDictionary)
            throw error
        }
        if let existing {
            let status = SecItemDelete(credentialQuery(existing.credentialRef) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound { throw ProfileStoreError.cleanupFailed(saved) }
        }
        return saved
    }

    func delete(_ profile: ConnectionProfile) throws {
        let original = try load()
        try write(original.filter { $0.id != profile.id })
        let status = SecItemDelete(credentialQuery(profile.credentialRef) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            try write(original)
            throw ProfileStoreError.keychain(status)
        }
    }

    /// Updates only display metadata, keeping credentials and connection identity untouched.
    func updateNote(_ profile: ConnectionProfile, note: String?) throws -> ConnectionProfile {
        var profiles = try load()
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw ProfileStoreError.recordNotFound
        }
        profiles[index].note = normalizedNote(note)
        try write(profiles)
        return profiles[index]
    }

    private func write(_ profiles: [ConnectionProfile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Document(schemaVersion: 1, profiles: profiles)).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func validateUniqueEdit(_ profile: ConnectionProfile, among profiles: [ConnectionProfile]) throws {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        if profiles.contains(where: {
            $0.id != profile.id && $0.serverHost == profile.serverHost && $0.serverPort == profile.serverPort && $0.username == profile.username
        }) { throw ProfileStoreError.duplicateConnection }
    }

    private func normalizedNote(_ note: String?) -> String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else { return nil }
        return note
    }

    private func credentialQuery(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppIdentity.bundleID,
         kSecAttrAccount as String: reference,
         kSecAttrSynchronizable as String: false]
    }
}
