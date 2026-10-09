import Foundation
import Security
import CryptoKit
import EngineerCore

@MainActor
final class MacKeychain: SessionCredentialStorage {
    private let service: String
    private let defaults: UserDefaults
    private var pendingLogoutKey: String { service + ".pendingLogout" }
    private var pendingSOLogoutKey: String { service + ".pendingSOLogout" }
    var snapshotNamespace: String { Self.digest(service) }

    init(config: AppConfig, defaults: UserDefaults = .standard) {
        // Mac-only namespace, bound to both configured origins; never reuse iOS credentials.
        let origins = (config.lumaWorkAPIOrigin ?? "") + "\n" + (config.simpleOneAPIOrigin ?? "")
        service = "septon.LumaWork.mac.session." + Self.digest(origins)
        self.defaults = defaults
    }

    func read() throws -> SessionCredentials? {
        // A failed Keychain deletion must not restore a logged-out account after restart.
        if defaults.bool(forKey: pendingLogoutKey) { try delete(); return nil }
        guard let data = try readData(account: "session") else { return nil }
        var value = try JSONDecoder().decode(SessionCredentials.self, from: data)
        if defaults.bool(forKey: pendingSOLogoutKey) { value.simpleOne = nil }
        guard !value.app.token.isEmpty, !value.app.user.id.isEmpty else {
            throw AppServiceError.message("Сохранённая сессия повреждена. Выйдите и войдите снова.")
        }
        return value
    }

    func write(_ credentials: SessionCredentials) throws {
        if credentials.simpleOne == nil { defaults.set(true, forKey: pendingSOLogoutKey) }
        try writeData(JSONEncoder().encode(credentials), account: "session")
        defaults.removeObject(forKey: pendingSOLogoutKey)
        defaults.removeObject(forKey: pendingLogoutKey)
    }

    func delete() throws {
        defaults.set(true, forKey: pendingLogoutKey)
        let status = SecItemDelete(query(account: "session") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        defaults.removeObject(forKey: pendingLogoutKey)
        defaults.removeObject(forKey: pendingSOLogoutKey)
    }

    func encryptionKey(for scope: SnapshotScope) throws -> Data {
        let account = "snapshot-key." + Self.digest(scope.userID)
        if let data = try readData(account: account) {
            guard data.count == 32 else { throw SnapshotStorageError.invalidKey }
            return data
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        try writeData(bytes, account: account)
        return bytes
    }

    func salaryPINData(userID: String) throws -> Data? { try readData(account: "salary-pin." + Self.digest(userID)) }
    func writeSalaryPINData(_ data: Data, userID: String) throws { try writeData(data, account: "salary-pin." + Self.digest(userID)) }

    private func query(account: String) -> [String: Any] {
        // Native macOS login Keychain: default local ACL; no iOS accessibility/access group.
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private func readData(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status) }
        return data
    }

    private func writeData(_ data: Data, account: String) throws {
        let query = query(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainFailure(status: status) }
        var addition = query
        addition[kSecValueData as String] = data
        let result = SecItemAdd(addition as CFDictionary, nil)
        guard result == errSecSuccess else { throw KeychainFailure(status: result) }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct KeychainFailure: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "Ошибка Keychain (\(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "операция недоступна")"
    }
}
