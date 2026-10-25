import Foundation

enum AppIdentity {
    static let bundleID = "io.github.yjcdon.miniEasyConnect"
    static let helperID = bundleID + ".helper"
    static let machService = helperID
    static let helperPlistName = helperID + ".plist"
    static let coreExecutableName = "minieasyconnect-core"

    static func signingRequirement(for identifier: String) -> String {
        guard let team = Bundle.main.object(forInfoDictionaryKey: "SigningTeamIdentifier") as? String,
              !team.isEmpty else {
            preconditionFailure("Missing application signing team")
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }
}

struct ConnectionProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var serverHost: String
    var serverPort: Int
    var username: String
    var credentialRef: String
    var note: String? = nil

    var displayName: String {
        if let note, !note.isEmpty { return note }
        return serverHost
    }
}

struct ConnectionRequest: Codable {
    let profile: ConnectionProfile
    let password: String
    let trustedCertificateSHA256: String?

    init(profile: ConnectionProfile, password: String, trustedCertificateSHA256: String? = nil) {
        self.profile = profile
        self.password = password
        self.trustedCertificateSHA256 = trustedCertificateSHA256
    }
}

enum ConnectionState: String, Codable {
    case disconnected, awaitingAuthorization, connecting, awaitingChallenge
    case connected, reconnecting, disconnecting, failed
}

struct AuthChallenge: Codable {
    let id: String
    let kind: String
    let message: String?
    let imageBase64: String?
    let certificateSHA256: String?

    init(id: String, kind: String, message: String? = nil, imageBase64: String? = nil, certificateSHA256: String? = nil) {
        self.id = id
        self.kind = kind
        self.message = message
        self.imageBase64 = imageBase64
        self.certificateSHA256 = certificateSHA256
    }
}

struct ConnectionSnapshot: Codable {
    var state: ConnectionState
    var sessionID: String?
    var message: String?
    var challenge: AuthChallenge?
    var retryable: Bool

    init(state: ConnectionState, sessionID: String? = nil, message: String? = nil, challenge: AuthChallenge? = nil, retryable: Bool = false) {
        self.state = state
        self.sessionID = sessionID
        self.message = message
        self.challenge = challenge
        self.retryable = retryable
    }
}

struct HelperCommand: Codable {
    let kind: String
    let request: ConnectionRequest?
    let challengeID: String?
    let answer: String?

    init(kind: String, request: ConnectionRequest? = nil, challengeID: String? = nil, answer: String? = nil) {
        self.kind = kind
        self.request = request
        self.challengeID = challengeID
        self.answer = answer
    }
}

struct HelperResponse: Codable {
    let ok: Bool
    let snapshot: ConnectionSnapshot
    let message: String?

    init(ok: Bool, snapshot: ConnectionSnapshot, message: String? = nil) {
        self.ok = ok
        self.snapshot = snapshot
        self.message = message
    }
}

@objc protocol HelperObserver {
    func changed(_ snapshot: Data)
}

@objc protocol HelperProtocol {
    func perform(_ command: Data, withReply reply: @escaping (Data) -> Void)
    func subscribe(_ observer: HelperObserver, withReply reply: @escaping (Data) -> Void)
}
