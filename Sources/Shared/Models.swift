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
}

struct ConnectionRequest: Codable {
    let profile: ConnectionProfile
    let password: String
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
}

struct ConnectionSnapshot: Codable {
    var state: ConnectionState
    var sessionID: String?
    var message: String?
    var challenge: AuthChallenge?

    init(state: ConnectionState, sessionID: String? = nil, message: String? = nil, challenge: AuthChallenge? = nil) {
        self.state = state
        self.sessionID = sessionID
        self.message = message
        self.challenge = challenge
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
