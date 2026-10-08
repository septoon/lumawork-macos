import Foundation

@MainActor
public protocol AppAuthenticating {
    func requestCode(email: String) async throws
    func verifyCode(email: String, code: String) async throws -> AppSession
    func currentUser(token: String) async throws -> AppUser
    func logout(token: String) async throws
}

extension LumaWorkAuthAPI: AppAuthenticating {}

@MainActor
public protocol SimpleOneAuthenticating {
    func login(username: String, password: String) async throws -> String
    func currentUser(authKey: String) async throws -> SimpleOneUser
}

@MainActor
public protocol SessionCredentialStorage {
    func read() throws -> SessionCredentials?
    func write(_ credentials: SessionCredentials) throws
    func delete() throws
}

public struct SessionCredentials: Codable, Sendable {
    public var app: AppSession
    public var simpleOne: SimpleOneSession?
    public init(app: AppSession, simpleOne: SimpleOneSession? = nil) {
        self.app = app
        self.simpleOne = simpleOne
    }
}

public struct SimpleOneSession: Codable, Hashable, Sendable {
    public var authKey: String
    public var user: SimpleOneUser
    public init(authKey: String, user: SimpleOneUser) {
        self.authKey = authKey
        self.user = user
    }
}

public struct SimpleOneUser: Codable, Hashable, Sendable {
    public var sysID: String
    public var username: String
    public var firstName: String
    public var lastName: String
    public init(sysID: String, username: String, firstName: String, lastName: String) {
        self.sysID = sysID; self.username = username
        self.firstName = firstName; self.lastName = lastName
    }
    public var displayName: String {
        [firstName, lastName].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum SessionConnection: Equatable, Sendable {
    case signedOut, restoring, online, offline, failed
}

// Captured before a request; rechecked before publishing or persisting its result.
public struct SessionContext: Equatable, Sendable {
    public let epoch: UInt64
    public let userID: String
    public let simpleOneUserID: String?
}
