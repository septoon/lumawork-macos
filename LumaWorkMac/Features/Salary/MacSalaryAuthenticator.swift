import Foundation
import CryptoKit
import Security
import LocalAuthentication
import EngineerCore

struct MacSalaryRecoveryProof {
    fileprivate let id: UUID
    fileprivate let context: SessionContext
    fileprivate let expires: Date
}
@MainActor
final class MacSalaryAuthenticator {
    private struct PINRecord: Codable { var salt: Data; var digest: Data; var failures: Int = 0; var blockedUntil: Date? }
    private let keychain: MacKeychain
    private let api: LumaWorkAuthAPI
    private let coordinator: EngineerApplicationCoordinator
    private var recoveryProofs: Set<UUID> = []
    init(keychain: MacKeychain, config: AppConfig, coordinator: EngineerApplicationCoordinator) { self.keychain = keychain; api = LumaWorkAuthAPI(config: config); self.coordinator = coordinator }
    private func record(_ userID: String) throws -> PINRecord? {
        guard let data = try keychain.salaryPINData(userID: userID) else { return nil }
        let record = try JSONDecoder().decode(PINRecord.self, from: data)
        guard record.salt.count == 32, record.digest.count == 32 else { throw AppServiceError.message("PIN повреждён. Восстановите его через почту.") }; return record
    }
    func hasPIN(_ userID: String) throws -> Bool { try record(userID) != nil }
    private func hash(_ pin: String, salt: Data) -> Data { Data(SHA256.hash(data: salt + Data(pin.utf8))) }
    private func validPIN(_ pin: String) -> Bool { pin.count == 4 && pin.allSatisfy { $0.isASCII && $0.isNumber } }
    func verifyPIN(_ pin: String, context: SessionContext) throws {
        guard coordinator.accepts(context), validPIN(pin), var record = try record(context.userID) else { throw AppServiceError.message("Введите PIN из четырёх цифр.") }
        if let blocked = record.blockedUntil, blocked > Date() { throw AppServiceError.message("Слишком много попыток. Подождите \(Int(ceil(blocked.timeIntervalSinceNow))) с.") }
        let value = hash(pin, salt: record.salt)
        let matches = zip(value, record.digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        if !matches { record.failures += 1; if record.failures >= 5 { record.blockedUntil = Date().addingTimeInterval(TimeInterval(min(300, 30 * (record.failures - 4)))) } }
        else { record.failures = 0; record.blockedUntil = nil }
        try keychain.writeSalaryPINData(JSONEncoder().encode(record), userID: context.userID)
        guard matches else { throw AppServiceError.message("Неверный PIN.") }
    }
    func setPIN(_ pin: String, confirmation: String, context: SessionContext, proof: MacSalaryRecoveryProof?) throws {
        guard coordinator.accepts(context), validPIN(pin), pin == confirmation else { throw AppServiceError.message("Укажите и повторите PIN из четырёх цифр.") }
        if try keychain.salaryPINData(userID: context.userID) != nil {
            guard let proof, proof.context == context, proof.expires > Date(), recoveryProofs.contains(proof.id) else { throw AppServiceError.message("Для смены PIN подтвердите почтовый код.") }
        }
        var salt = Data(count: 32)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw AppServiceError.message("Не удалось создать PIN.") }
        let value = PINRecord(salt: salt, digest: hash(pin, salt: salt))
        try keychain.writeSalaryPINData(JSONEncoder().encode(value), userID: context.userID)
        if let proof { recoveryProofs.remove(proof.id) }
    }
    private func preferenceKey(_ userID: String) -> String { "salary.biometry." + keychain.snapshotNamespace + "." + SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined() }
    func biometricEnabled(_ userID: String) -> Bool { UserDefaults.standard.object(forKey: preferenceKey(userID)) as? Bool ?? true }
    func setBiometricEnabled(_ enabled: Bool, userID: String) { UserDefaults.standard.set(enabled, forKey: preferenceKey(userID)) }
    func canAutomaticallyAuthenticate(_ userID: String) -> Bool { (try? hasPIN(userID)) == true && biometricEnabled(userID) && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) }
    func authenticate(_ context: LAContext, automatically: Bool, account: SessionContext) async throws {
        guard coordinator.accepts(account), try hasPIN(account.userID) else { throw AppServiceError.message("Сначала настройте PIN.") }
        let policy: LAPolicy = automatically ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: nil) else { throw AppServiceError.message("Системная проверка недоступна. Введите PIN.") }
        let success = try await context.evaluatePolicy(policy, localizedReason: "Открыть раздел «Зарплата»")
        guard success, coordinator.accepts(account) else { throw CancellationError() }
    }
    func requestCode(context: SessionContext) async throws {
        guard coordinator.accepts(context), let email = coordinator.session?.user.email, !email.isEmpty else { throw CancellationError() }
        try await api.requestCode(email: email)
        guard coordinator.accepts(context) else { throw CancellationError() }
    }
    func verifyCode(_ code: String, context: SessionContext) async throws -> MacSalaryRecoveryProof {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }), coordinator.accepts(context), let email = coordinator.session?.user.email else { throw AppServiceError.message("Введите шестизначный код из письма.") }
        let verified = try await api.verifyCode(email: email, code: code)
        guard coordinator.accepts(context), verified.user.id == context.userID, verified.user.email.lowercased() == email.lowercased() else { throw CancellationError() }
        // Verification proves identity; never replace the active app/SimpleOne session.
        let proof = MacSalaryRecoveryProof(id: UUID(), context: context, expires: Date().addingTimeInterval(180))
        recoveryProofs = [proof.id]; return proof
    }
    func discard(_ proof: MacSalaryRecoveryProof?) { if let proof { recoveryProofs.remove(proof.id) } }
}
