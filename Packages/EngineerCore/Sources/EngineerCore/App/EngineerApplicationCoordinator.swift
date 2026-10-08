import Foundation
import Observation

@MainActor @Observable
public final class EngineerApplicationCoordinator {
    public private(set) var session: AppSession?
    public private(set) var simpleOneSession: SimpleOneSession?
    public private(set) var appConnection = SessionConnection.signedOut
    public private(set) var simpleOneConnection = SessionConnection.signedOut
    public private(set) var epoch: UInt64 = 0
    public private(set) var isAuthenticating = false
    public private(set) var isSimpleOneAuthenticating = false
    public private(set) var appError: String?
    public private(set) var simpleOneError: String?
    public private(set) var protectedContentGeneration: UInt64 = 0

    private let appAPI: any AppAuthenticating
    private let simpleOneAPI: any SimpleOneAuthenticating
    private let credentials: any SessionCredentialStorage
    @ObservationIgnored private var retained: SessionCredentials?
    @ObservationIgnored private var appOperation: Task<Bool, Never>?
    @ObservationIgnored private var soOperation: Task<Bool, Never>?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var appAuthGeneration: UInt64 = 0
    @ObservationIgnored private var soAuthGeneration: UInt64 = 0
    @ObservationIgnored private var appOperationID: UUID?
    @ObservationIgnored private var soOperationID: UUID?

    public init(appAPI: any AppAuthenticating, simpleOneAPI: any SimpleOneAuthenticating, credentials: any SessionCredentialStorage) {
        self.appAPI = appAPI; self.simpleOneAPI = simpleOneAPI; self.credentials = credentials
    }

    public var context: SessionContext? {
        guard let session, appConnection == .online || appConnection == .offline else { return nil }
        return SessionContext(epoch: epoch, userID: session.user.id, simpleOneUserID: simpleOneSession?.user.sysID)
    }
    public func accepts(_ captured: SessionContext) -> Bool { context == captured }

    public func restore() async {
        guard !restored else { return }
        do {
            retained = try credentials.read()
            if let app = retained?.app, app.token.isEmpty || app.user.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                invalidateSession(message: "Сохранённая сессия повреждена. Войдите снова.")
            }
            if var saved = retained, let so = saved.simpleOne,
               so.authKey.isEmpty || so.user.sysID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                saved.simpleOne = nil
                try credentials.write(saved)
                retained = saved
            }
            restored = true
        } catch {
            appConnection = .failed; appError = error.localizedDescription
            return
        }
        await refreshSession()
    }

    public func retryRestore() async {
        if retained == nil { restored = false; await restore() }
        else { await refreshSession() }
    }

    public func refreshSession() async {
        if let appOperation { _ = await appOperation.value; return }
        guard let saved = retained else { return }
        let ticket = appAuthGeneration
        let operationID = UUID()
        appOperationID = operationID
        appConnection = .restoring
        appError = nil
        isAuthenticating = true
        let task = Task { [self] in
            do {
                let user = try await appAPI.currentUser(token: saved.app.token)
                guard isCurrent(ticket) else { return false }
                guard user.id == saved.app.user.id else {
                    invalidateSession(message: "Сервер вернул другого пользователя. Войдите снова.")
                    return false
                }
                guard var updated = retained else { return false }
                updated.app.user = user
                try credentials.write(updated)
                if session?.user != user { advanceEpoch() }
                retained = updated; session = updated.app
                appConnection = .online
                return true
            } catch {
                guard isCurrent(ticket) else { return false }
                if Self.isAppUnauthorized(error) {
                    invalidateSession(message: error.localizedDescription)
                } else if case .network = AppErrorClassification.classification(for: error) {
                    session = saved.app; appConnection = .offline
                    appError = error.localizedDescription
                } else if !AppErrorClassification.isCancellation(error) {
                    session = nil; simpleOneSession = nil; simpleOneConnection = .signedOut
                    appConnection = .failed; appError = error.localizedDescription
                    advanceEpoch()
                } else {
                    appConnection = session == nil ? .signedOut : .offline
                }
                return false
            }
        }
        appOperation = task
        _ = await task.value
        // A successful permission refresh can advance the epoch; operation identity is separate.
        guard appOperationID == operationID else { return }
        appOperation = nil; appOperationID = nil; isAuthenticating = false
        if session != nil, retained?.simpleOne != nil { await refreshSimpleOne() }
    }

    public func requestCode(email: String) async -> Bool {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { appError = "Введите почту."; return false }
        return await performAppAuth { [appAPI] in
            try await appAPI.requestCode(email: email)
            return nil
        }
    }

    public func verifyCode(email: String, code: String) async -> Bool {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { appError = "Введите почту."; return false }
        guard code.count == 6 else { appError = "Введите 6-значный код."; return false }
        return await performAppAuth { [appAPI] in try await appAPI.verifyCode(email: email, code: code) }
    }

    private func performAppAuth(_ operation: @escaping @MainActor () async throws -> AppSession?) async -> Bool {
        guard appOperation == nil, session == nil else { return false }
        let ticket = appAuthGeneration
        let operationID = UUID()
        appOperationID = operationID
        appError = nil; isAuthenticating = true
        let task = Task { [self] in
            do {
                let result = try await operation()
                guard isCurrent(ticket) else { return false }
                if let result {
                    guard !result.token.isEmpty, !result.user.id.isEmpty else {
                        throw AppServiceError.message("Сервер авторизации вернул некорректный ответ.")
                    }
                    let saved = SessionCredentials(app: result)
                    try credentials.write(saved)
                    advanceEpoch()
                    appAuthGeneration &+= 1
                    retained = saved; session = result; restored = true
                    simpleOneSession = nil; simpleOneConnection = .signedOut
                    appConnection = .online
                }
                return true
            } catch {
                if isCurrent(ticket), !AppErrorClassification.isCancellation(error) { appError = error.localizedDescription }
                return false
            }
        }
        appOperation = task
        let result = await task.value
        // A stale task cannot clear a newer account's operation.
        if appOperationID == operationID {
            appOperation = nil; appOperationID = nil; isAuthenticating = false
        }
        return result
    }

    public func loginSimpleOne(username: String, password: String) async -> Bool {
        guard appConnection == .online, session != nil, soOperation == nil else { return false }
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            simpleOneError = "Введите логин и пароль SimpleOne."; return false
        }
        return await performSimpleOne { [simpleOneAPI] in
            let key = try await simpleOneAPI.login(username: username, password: password)
            let user = try await simpleOneAPI.currentUser(authKey: key)
            return SimpleOneSession(authKey: key, user: user)
        }
    }

    public func refreshSimpleOne() async {
        if let soOperation { _ = await soOperation.value; return }
        guard session != nil, let saved = retained?.simpleOne else { return }
        simpleOneConnection = .restoring
        _ = await performSimpleOne { [simpleOneAPI] in
            let user = try await simpleOneAPI.currentUser(authKey: saved.authKey)
            guard user.sysID == saved.user.sysID else { throw SimpleOneServiceError.unauthorized }
            return SimpleOneSession(authKey: saved.authKey, user: user)
        }
    }

    private func performSimpleOne(_ operation: @escaping @MainActor () async throws -> SimpleOneSession) async -> Bool {
        guard let captured = context else { return false }
        let appTicket = appAuthGeneration
        let soTicket = soAuthGeneration
        let operationID = UUID()
        soOperationID = operationID
        simpleOneError = nil; isSimpleOneAuthenticating = true
        let task = Task { [self] in
            do {
                let result = try await operation()
                guard acceptsSOOperation(appTicket: appTicket, soTicket: soTicket, userID: captured.userID), var saved = retained else { return false }
                saved.simpleOne = result
                try credentials.write(saved)
                advanceEpoch()
                soAuthGeneration &+= 1
                retained = saved; simpleOneSession = result; simpleOneConnection = .online
                return true
            } catch {
                guard acceptsSOOperation(appTicket: appTicket, soTicket: soTicket, userID: captured.userID) else { return false }
                if Self.isSOUnauthorized(error) {
                    disconnectSimpleOne()
                } else if case .network = AppErrorClassification.classification(for: error), let saved = retained?.simpleOne {
                    simpleOneSession = saved; simpleOneConnection = .offline
                } else {
                    simpleOneConnection = .failed; simpleOneSession = nil
                    advanceEpoch()
                }
                if !AppErrorClassification.isCancellation(error) { simpleOneError = error.localizedDescription }
                return false
            }
        }
        soOperation = task
        let result = await task.value
        if soOperationID == operationID {
            soOperation = nil; soOperationID = nil; isSimpleOneAuthenticating = false
        }
        return result
    }

    public func disconnectSimpleOne() {
        soOperation?.cancel(); soOperation = nil; soOperationID = nil; isSimpleOneAuthenticating = false
        soAuthGeneration &+= 1
        advanceEpoch()
        simpleOneSession = nil; simpleOneConnection = .signedOut; simpleOneError = nil
        guard var saved = retained else { return }
        saved.simpleOne = nil; retained = saved
        do { try credentials.write(saved) } catch { simpleOneError = error.localizedDescription }
    }

    public func logout() async {
        let token = session?.token ?? retained?.app.token
        invalidateSession()
        let ticket = epoch
        guard let token else { return }
        do { try await appAPI.logout(token: token) }
        catch {
            if epoch == ticket, !AppErrorClassification.isCancellation(error) {
                appError = "Локальный выход выполнен. Не удалось отозвать сессию на сервере: \(error.localizedDescription)"
            }
        }
    }

    public func invalidateSession(message: String? = nil) {
        appOperation?.cancel(); soOperation?.cancel()
        appOperation = nil; soOperation = nil
        appOperationID = nil; soOperationID = nil
        appAuthGeneration &+= 1; soAuthGeneration &+= 1
        advanceEpoch()
        session = nil; retained = nil; simpleOneSession = nil
        appConnection = .signedOut; simpleOneConnection = .signedOut
        isAuthenticating = false; isSimpleOneAuthenticating = false
        appError = message; simpleOneError = nil
        do { try credentials.delete() }
        catch { appError = "Не удалось удалить credentials из Keychain: \(error.localizedDescription)" }
    }

    public func lockProtectedContent() { protectedContentGeneration &+= 1 }
    public func resumeAfterWake() async { await refreshSession() }

    private func isCurrent(_ ticket: UInt64) -> Bool { ticket == appAuthGeneration && !Task.isCancelled }
    private func acceptsSOOperation(appTicket: UInt64, soTicket: UInt64, userID: String) -> Bool {
        appAuthGeneration == appTicket && soAuthGeneration == soTicket && session?.user.id == userID && !Task.isCancelled
    }
    private static func isSOUnauthorized(_ error: Error) -> Bool {
        guard let error = error as? SimpleOneServiceError else { return false }
        switch error {
        case .unauthorized, .invalidCredentials, .forbidden: return true
        default: return false
        }
    }
    private func advanceEpoch() { epoch &+= 1; lockProtectedContent() }
    private static func isAppUnauthorized(_ error: Error) -> Bool {
        if LumaWorkAuthError.isAccessRevoked(error) { return true }
        if case AppServiceError.http(let status, _) = error { return status == 401 || status == 403 }
        return false
    }
}
