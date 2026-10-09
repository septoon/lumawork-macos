import Foundation
import CryptoKit
import Observation

@MainActor @Observable
public final class FTPRepository {
    private struct Snapshot: Codable { var directories: [String: [FTPItem]]; var favorites: Set<String>; var transfers: [FTPTransfer]; var destinationBookmark: Data? }
    private let session: () -> AppSession?
    private let context: () -> SessionContext?
    private let storage: () throws -> ScopedSnapshotStorage
    private let service: (AppSession) -> FTPService
    private let filesRoot: URL
    private let authFailure: () -> Void
    private var bound: SessionContext?
    private var directories: [String: [FTPItem]] = [:]
    public private(set) var destinationBookmark: Data?
    public private(set) var favorites: Set<String> = []
    public private(set) var transfers: [FTPTransfer] = []
    public private(set) var errors: [String: String] = [:]
    public private(set) var offlinePaths: Set<String> = []
    public private(set) var cacheWarning: String?
    private var loaded: Set<String> = []
    private var hydration: Task<Void, Error>?
    private var hydrated = false
    private var flights: [String: Task<Void, Error>] = [:]
    private var enqueueAttempts: [UUID: UUID] = [:]
    private var downloads: [UUID: Task<Void, Never>] = [:]
    private var persistence: Task<Void, Error>?
    private var revision = 0
    public init(session: @escaping () -> AppSession?, context: @escaping () -> SessionContext?, storage: @escaping () throws -> ScopedSnapshotStorage, service: @escaping (AppSession) -> FTPService, filesRoot: URL, authFailure: @escaping () -> Void) {
        self.session = session; self.context = context; self.storage = storage; self.service = service; self.filesRoot = filesRoot; self.authFailure = authFailure
    }
    public func synchronizeSession() {
        guard bound != context() else { return }
        flights.values.forEach { $0.cancel() }; downloads.values.forEach { $0.cancel() }; hydration?.cancel(); persistence?.cancel()
        bound = context(); destinationBookmark = nil; enqueueAttempts = [:]; directories = [:]; favorites = []; transfers = []; errors = [:]; offlinePaths = []; loaded = []; hydration = nil; hydrated = false; flights = [:]; downloads = [:]; persistence = nil; revision = 0; cacheWarning = nil
    }
    public func items(_ path: String) -> [FTPItem] { bound == context() ? directories[path] ?? [] : [] }
    public func hasSnapshot(_ path: String) -> Bool { bound == context() && directories[path] != nil }
    public func isLoading(_ path: String) -> Bool { flights[path] != nil || hydration != nil }
    private func check(_ captured: SessionContext) throws { try Task.checkCancellation(); guard bound == captured, context() == captured else { throw CancellationError() } }
    private func capture() throws -> (SessionContext, FTPService) {
        synchronizeSession(); guard let captured = bound, let session = session(), session.user.id == captured.userID else { throw CancellationError() }; return (captured, service(session))
    }
    private func hydrate(_ captured: SessionContext) async throws {
        if hydrated { return }
        if let hydration { try await hydration.value; try check(captured); return }
        let vault = try storage(), scope = try SnapshotScope(userID: captured.userID)
        let task = Task {
            do {
                let data = try await vault.load(key: "ftp.v1", scope: scope); try self.check(captured)
                if let data {
                    let value = try JSONDecoder().decode(Snapshot.self, from: data)
                    self.directories = value.directories; self.favorites = value.favorites; self.destinationBookmark = value.destinationBookmark
                    self.transfers = value.transfers.map { record in
                        var record = record
                        let local = try? self.fileURL(id: record.id, name: record.fileName, captured: captured)
                        if let local, FileManager.default.fileExists(atPath: local.path) {
                            record.state = .completed; record.error = nil
                            record.bytesWritten = Int64((try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0); record.expectedBytes = record.bytesWritten
                        } else if record.isActive { record.state = .failed; record.error = "Скачивание прервано закрытием приложения. Повторите после проверки каталога." }
                        else if record.state == .completed { record.state = .failed; record.error = "Скачанный файл не найден на Mac." }
                        return record
                    }
                }
            } catch { try self.check(captured); self.cacheWarning = "Локальная история FTP недоступна." }
            self.hydrated = true
        }; hydration = task
        defer { if bound == captured { hydration = nil } }
        try await task.value; try check(captured)
    }
    private func persist(_ captured: SessionContext) async throws {
        try check(captured); revision += 1
        do {
            let task: Task<Void, Error>
            if let persistence { task = persistence }
            else {
                let vault = try storage(), scope = try SnapshotScope(userID: captured.userID)
                task = Task {
                    repeat {
                        try self.check(captured); let version = self.revision
                        let snapshot = Snapshot(directories: self.directories, favorites: self.favorites, transfers: self.transfers, destinationBookmark: self.destinationBookmark)
                        try await vault.save(JSONEncoder().encode(snapshot), key: "ftp.v1", scope: scope); try self.check(captured)
                        if version == self.revision { break }
                    } while true
                }; persistence = task
            }
            do { try await task.value; try check(captured); persistence = nil; cacheWarning = nil }
            catch { if bound == captured { persistence = nil }; throw error }
        } catch { try check(captured); cacheWarning = "История FTP не сохранена. Скачанные файлы остаются на Mac." }
    }
    private func record(_ error: Error, path: String) {
        errors[path] = error.localizedDescription
        if case .network = AppErrorClassification.classification(for: error) { offlinePaths.insert(path) }
        if DomainHTTPClient.isUnauthorized(error) { authFailure() }
    }
    public func load(_ path: String, force: Bool = false) async throws {
        let (captured, api) = try capture(), path = try FTPService.path(path)
        try await hydrate(captured); try check(captured)
        if let flight = flights[path] { try await flight.value; try check(captured); return }
        if loaded.contains(path), !force { return }
        let task = Task {
            do { let result = try await api.directory(path); try self.check(captured); self.directories[path] = result.items; self.loaded.insert(path); self.errors[path] = nil; self.offlinePaths.remove(path); try await self.persist(captured) }
            catch { try self.check(captured); self.record(error, path: path); throw error }
        }; flights[path] = task
        defer { if bound == captured { flights[path] = nil } }
        try await task.value; try check(captured)
    }
    public func setDestinationBookmark(_ value: Data?) async throws {
        let (captured, _) = try capture(); try await hydrate(captured); try check(captured)
        destinationBookmark = value; try await persist(captured)
    }
    public func toggleFavorite(_ path: String) async throws {
        let (captured, _) = try capture(), path = try FTPService.path(path); guard path != "/" else { return }
        try await hydrate(captured); try check(captured)
        if favorites.contains(path) { favorites.remove(path) } else { favorites.insert(path) }
        try await persist(captured)
    }
    public func isRunning(_ id: UUID) -> Bool { downloads[id] != nil }
    public func enqueue(_ item: FTPItem, retrying id: UUID? = nil) async throws {
        let (captured, api) = try capture(); try await hydrate(captured); try check(captured)
        guard !transfers.contains(where: { $0.item.path == item.path && $0.isActive }) else { return }
        if let id { guard downloads[id] == nil else { throw GsmFuelError.busy }; guard let prior = transfers.first(where: { $0.id == id }), !prior.isActive, prior.state != .completed else { throw GsmFuelError.busy } }
        let id = id ?? UUID(), attempt = UUID(); enqueueAttempts[id] = attempt
        transfers.removeAll { $0.id == id }
        transfers.insert(FTPTransfer(id: id, item: item, createdAt: Date(), state: .preparing, bytesWritten: 0), at: 0)
        try await persist(captured); try check(captured)
        guard enqueueAttempts[id] == attempt, transfers.first(where: { $0.id == id })?.isActive == true else { return }
        let task = Task { await self.performDownload(id: id, item: item, api: api, captured: captured) }
        downloads[id] = task
    }
    private func performDownload(id: UUID, item: FTPItem, api: FTPService, captured: SessionContext) async {
        defer { if bound == captured { downloads[id] = nil; enqueueAttempts[id] = nil } }
        var temporary: URL?
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        do {
            // Manual retries and initial downloads both verify the current remote entry first.
            let directory = try await api.directory(item.parent); try check(captured)
            guard let current = directory.items.first(where: { $0.path == item.path && $0.type == item.type }) else { throw AppServiceError.http(status: 404, fallback: "Файл или папка больше не доступны. Обновите каталог") }
            directories[item.parent] = directory.items
            update(id) { $0.item = current; $0.state = .downloading }
            try await persist(captured); try check(captured)
            let file = try await api.download(current) { [weak self] bytes, expected in
                Task { @MainActor in
                    guard let self, self.bound == captured, self.context() == captured, self.transfers.first(where: { $0.id == id })?.state == .downloading else { return }
                    self.update(id) { $0.bytesWritten = bytes; $0.expectedBytes = expected }
                }
            }; temporary = file
            try check(captured)
            guard transfers.first(where: { $0.id == id })?.state == .downloading else { throw CancellationError() }
            let destination = try fileURL(id: id, name: current.name + (current.isDirectory ? ".zip" : ""), captured: captured)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: file, to: destination); temporary = nil
            update(id) { $0.state = .completed; $0.error = nil; $0.bytesWritten = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0); $0.expectedBytes = $0.bytesWritten }
            try await persist(captured)
        } catch {
            guard bound == captured, context() == captured else { return }
            if transfers.first(where: { $0.id == id })?.state != .cancelled {
                update(id) { $0.state = AppErrorClassification.isCancellation(error) ? .cancelled : .failed; $0.error = AppErrorClassification.isCancellation(error) ? nil : error.localizedDescription }
                if !AppErrorClassification.isCancellation(error) { record(error, path: item.parent) }
            }
            try? await persist(captured)
        }
    }
    private func update(_ id: UUID, _ change: (inout FTPTransfer) -> Void) { if let index = transfers.firstIndex(where: { $0.id == id }) { change(&transfers[index]) } }
    public func cancel(_ id: UUID) async throws {
        let (captured, _) = try capture(); guard transfers.first(where: { $0.id == id })?.isActive == true else { return }
        enqueueAttempts[id] = nil; update(id) { $0.state = .cancelled; $0.error = nil }; downloads[id]?.cancel(); try await persist(captured)
    }
    public func removeHistory(_ id: UUID) async throws {
        let (captured, _) = try capture(); guard transfers.first(where: { $0.id == id })?.isActive == false else { return }
        transfers.removeAll { $0.id == id }; try await persist(captured) // Deliberately retains the completed managed file.
    }
    private func fileURL(id: UUID, name: String, captured: SessionContext) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw GsmFuelError.invalidResponse }
        let owner = SHA256.hash(data: Data(captured.userID.utf8)).map { String(format: "%02x", $0) }.joined()
        return filesRoot.appendingPathComponent(owner, isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(name)
    }
    public func localFile(_ id: UUID) -> URL? {
        guard bound == context(), let captured = bound, let record = transfers.first(where: { $0.id == id && $0.state == .completed }), let url = try? fileURL(id: id, name: record.fileName, captured: captured), FileManager.default.fileExists(atPath: url.path) else { return nil }; return url
    }
    public func deleteLocalFile(_ id: UUID) async throws {
        let (captured, _) = try capture(); guard let url = localFile(id) else { throw AppServiceError.message("Скачанный файл не найден.") }
        try FileManager.default.removeItem(at: url)
        update(id) { $0.state = .failed; $0.error = "Локальный файл удалён." }; try await persist(captured)
    }
    public func managedDirectory() -> URL? {
        guard bound == context(), let captured = bound else { return nil }
        return try? fileURL(id: UUID(), name: "file", captured: captured).deletingLastPathComponent().deletingLastPathComponent()
    }
}
