import SwiftUI
import AppKit
import LocalAuthentication
import EngineerCore

@MainActor @Observable
final class MacSalaryWorkspace {
    enum Mode { case unlock, setup, recovery, code }
    var grant: SalaryAccessGrant?
    var editor: MacSalaryEditorModel?
    var month: String?
    var selection: String?
    var hidesAmounts = true
    var pin = ""
    var confirmation = ""
    var code = ""
    var mode: Mode = .unlock
    var busy = false
    var isPresented = false
    var error: String?
    var notice: String?
    var biometricEnabled = true
    private var operation: UUID?
    private var systemContext: LAContext?
    private var recoveryProof: MacSalaryRecoveryProof?
    var hasDirty: Bool { editor?.isDirty == true }
    func discardEditor() { editor = nil }
    func lock(access: SalaryAccess, authenticator: MacSalaryAuthenticator, cancelAuthentication: Bool = true) {
        access.revoke(grant); grant = nil; editor = nil; month = nil; selection = nil; pin = ""; confirmation = ""; code = ""; notice = nil; error = nil
        if cancelAuthentication { operation = nil; systemContext?.invalidate(); systemContext = nil; busy = false; authenticator.discard(recoveryProof); recoveryProof = nil; mode = .unlock }
    }
    func prepare(authenticator: MacSalaryAuthenticator, coordinator: EngineerApplicationCoordinator) {
        isPresented = true
        guard let context = coordinator.context else { return }
        do { mode = try authenticator.hasPIN(context.userID) ? .unlock : .setup; biometricEnabled = authenticator.biometricEnabled(context.userID) }
        catch { self.error = "PIN недоступен. Восстановите его через почтовый код."; mode = .recovery }
    }
    private func authorize(access: SalaryAccess, coordinator: EngineerApplicationCoordinator, context: SessionContext) throws {
        guard isPresented, NSApp.isActive, coordinator.accepts(context) else { throw CancellationError() }
        grant = try access.authorize(expectedContext: context, expectedGeneration: coordinator.protectedContentGeneration)
        pin = ""; confirmation = ""; code = ""; recoveryProof = nil; error = nil
    }
    func submitPIN(authenticator: MacSalaryAuthenticator, access: SalaryAccess, coordinator: EngineerApplicationCoordinator) {
        guard !busy, isPresented, let context = coordinator.context else { return }
        do {
            if mode == .setup { try authenticator.setPIN(pin, confirmation: confirmation, context: context, proof: recoveryProof); access.lockAll() }
            else { try authenticator.verifyPIN(pin, context: context) }
            try authorize(access: access, coordinator: coordinator, context: context)
        } catch { self.error = error.localizedDescription; pin = ""; confirmation = "" }
    }
    func systemUnlock(authenticator: MacSalaryAuthenticator, access: SalaryAccess, coordinator: EngineerApplicationCoordinator, automatically: Bool = false) async {
        guard !busy, isPresented, NSApp.isActive, let context = coordinator.context else { return }
        let id = UUID(); operation = id; busy = true; error = nil
        let system = LAContext(); systemContext = system
        defer { if operation == id { busy = false; systemContext = nil } }
        do {
            try await authenticator.authenticate(system, automatically: automatically, account: context)
            guard operation == id, isPresented, coordinator.accepts(context) else { return }
            try authorize(access: access, coordinator: coordinator, context: context)
        } catch { if operation == id, isPresented, coordinator.accepts(context) { self.error = "Системная проверка не завершена. Можно войти по PIN." } }
    }
    func recover(authenticator: MacSalaryAuthenticator, coordinator: EngineerApplicationCoordinator) async {
        guard !busy, isPresented, let context = coordinator.context else { return }
        let id = UUID(); operation = id; busy = true; error = nil
        defer { if operation == id { busy = false } }
        do {
            if mode == .code {
                let proof = try await authenticator.verifyCode(code, context: context)
                guard operation == id, isPresented, coordinator.accepts(context) else { authenticator.discard(proof); return }
                recoveryProof = proof; mode = .setup; code = ""; notice = "Задайте новый PIN."
            } else {
                try await authenticator.requestCode(context: context)
                guard operation == id, isPresented, coordinator.accepts(context) else { return }
                mode = .code; notice = "Код отправлен на почту вашей учётной записи."
            }
        } catch { if operation == id, isPresented, coordinator.accepts(context) { self.error = error.localizedDescription } }
    }
}
@MainActor @Observable
final class MacSalaryEditorModel: Identifiable {
    let id = UUID()
    let base: SalaryEntry?
    let context: SessionContext
    let grant: SalaryAccessGrant
    var date: Date
    var period: String
    var amount: String
    var baseSalary: String
    var weekendPay: String
    var kind: SalaryPaymentKind
    var comment: String
    var isSaving = false
    var error: String?
    private var initial = ""
    init(base: SalaryEntry?, context: SessionContext, grant: SalaryAccessGrant) {
        self.base = base; self.context = context; self.grant = grant
        let initialDate = base.flatMap { MacRouteDate.date($0.date) } ?? Date()
        date = initialDate
        period = base?.accrualMonthKey ?? SalaryEntry.inferredPeriodMonth(for: MacRouteDate.key(initialDate))
        amount = base.map { String($0.netPaymentAmount) } ?? ""; baseSalary = base.map { String($0.baseSalary) } ?? ""; weekendPay = base.map { String($0.weekendPay) } ?? ""
        kind = base?.paymentKind ?? ((Int(MacRouteDate.key(initialDate).suffix(2)) ?? 0) <= 10 ? .salary : .advance)
        comment = base?.comment ?? ""; initial = fingerprint
    }
    var usesNetAmount: Bool { base?.amount != nil || MacRouteDate.key(date) >= SalaryEntry.netPaymentStartDate }
    private var fingerprint: String { [MacRouteDate.key(date), period, amount, baseSalary, weekendPay, kind.rawValue, comment].joined(separator: "\u{0}") }
    var isDirty: Bool { initial != fingerprint }
    func entry() throws -> SalaryEntry {
        func parse(_ value: String) throws -> Double { guard let result = Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), result.isFinite, result >= 0 else { throw AppServiceError.message("Укажите корректную сумму.") }; return result }
        let value = SalaryEntry(id: base?.id, date: MacRouteDate.key(date), baseSalary: usesNetAmount ? 0 : try parse(baseSalary), weekendPay: usesNetAmount || weekendPay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : try parse(weekendPay), periodMonth: period, amount: usesNetAmount ? try parse(amount) : nil, kind: kind, comment: comment.isEmpty ? nil : comment)
        _ = try SalaryService.payload(value); return value
    }
}
