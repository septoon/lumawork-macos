import Foundation
import CryptoKit

public struct SnapshotScope: Hashable, Sendable {
    public let userID: String
    public let simpleOneUserID: String?
    public init(userID: String, simpleOneUserID: String? = nil) throws {
        guard !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              simpleOneUserID.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true else {
            throw SnapshotStorageError.missingIdentity
        }
        self.userID = userID; self.simpleOneUserID = simpleOneUserID
    }
}

public enum SnapshotStorageError: LocalizedError {
    case missingIdentity, corrupted, invalidKey
    case unsupportedSchema(Int)
    public var errorDescription: String? {
        switch self {
        case .missingIdentity: "Для кеша требуется подтверждённый пользователь."
        case .corrupted: "Кеш повреждён. Файл сохранён для восстановления; загрузите данные снова."
        case .invalidKey: "Не удалось получить ключ шифрования кеша."
        case .unsupportedSchema: "Эта версия кеша не поддерживается. Исходный файл сохранён."
        }
    }
}

// One serial writer per app. All payloads are encrypted, including future sensitive domains.
public actor ScopedSnapshotStorage {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let sealed: Data
    }
    private let root: URL
    private let keyProvider: @Sendable (SnapshotScope) async throws -> Data
    private let writeFile: @Sendable (Data, URL) throws -> Void

    public init(root: URL, keyProvider: @escaping @Sendable (SnapshotScope) async throws -> Data,
                writeFile: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.root = root; self.keyProvider = keyProvider; self.writeFile = writeFile
    }

    public func fileURL(key: String, scope: SnapshotScope) -> URL {
        // Length-delimited components prevent ambiguous identities and path traversal.
        let identity = Self.identity(scope)
        return root.appendingPathComponent(Self.digest(identity), isDirectory: true)
            .appendingPathComponent(Self.digest(Data(key.utf8)) + ".json")
    }

    public func save(_ data: Data, key: String, scope: SnapshotScope) async throws {
        let encryptionKey = try await keyProvider(scope)
        try Task.checkCancellation()
        guard encryptionKey.count == 32 else { throw SnapshotStorageError.invalidKey }
        let authenticated = Self.identity(scope) + Data(key.utf8)
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: encryptionKey), authenticating: authenticated)
        guard let combined = box.combined else { throw SnapshotStorageError.corrupted }
        let encoded = try JSONEncoder().encode(Envelope(schemaVersion: 1, sealed: combined))
        let url = fileURL(key: key, scope: scope)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        // No suspension between final cancellation check and atomic replacement.
        try Task.checkCancellation()
        try writeFile(encoded, url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load(key: String, scope: SnapshotScope) async throws -> Data? {
        let url = fileURL(key: key, scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { try quarantine(url); throw SnapshotStorageError.corrupted }
        guard envelope.schemaVersion == 1 else { throw SnapshotStorageError.unsupportedSchema(envelope.schemaVersion) }
        let encryptionKey = try await keyProvider(scope)
        try Task.checkCancellation()
        guard encryptionKey.count == 32 else { throw SnapshotStorageError.invalidKey }
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            return try AES.GCM.open(box, using: SymmetricKey(data: encryptionKey), authenticating: Self.identity(scope) + Data(key.utf8))
        } catch {
            // The actor can re-enter while obtaining a Keychain key. Preserve a newer write.
            if (try? Data(contentsOf: url)) == data { try quarantine(url) }
            throw SnapshotStorageError.corrupted
        }
    }

    private func quarantine(_ url: URL) throws {
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("quarantine-" + UUID().uuidString))
    }
    private static func identity(_ scope: SnapshotScope) -> Data {
        let parts = [scope.userID, scope.simpleOneUserID ?? ""]
        return Data(parts.map { "\($0.utf8.count):\($0)" }.joined().utf8)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
