import Foundation

public struct FTPItem: Codable, Hashable, Identifiable, Sendable {
    public enum ItemType: String, Codable, Sendable { case directory, file }
    public let name: String
    public let path: String
    public let type: ItemType
    public let size: Int64?
    public let sizeText: String?
    public let modifiedAt: String?
    public var id: String { path }
    public var isDirectory: Bool { type == .directory }
    public var parent: String { (path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent }
}
public struct FTPDirectory: Codable, Sendable { public let path: String; public let items: [FTPItem] }
public struct FTPTransfer: Codable, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case preparing, downloading, completed, failed, cancelled }
    public let id: UUID
    public var item: FTPItem
    public let createdAt: Date
    public var state: State
    public var bytesWritten: Int64
    public var expectedBytes: Int64?
    public var error: String?
    public var isActive: Bool { state == .preparing || state == .downloading }
    public var fileName: String { item.name + (item.isDirectory ? ".zip" : "") }
    public var progress: Double? { expectedBytes.flatMap { $0 > 0 ? min(1, Double(bytesWritten) / Double($0)) : nil } }
    public var stateTitle: String { switch state { case .preparing: "Подготовка"; case .downloading: "Скачивание"; case .completed: "Скачано"; case .failed: "Ошибка"; case .cancelled: "Отменено" } }
}
public struct FTPService {
    private let http: DomainHTTPClient
    private let files: AuthenticatedFileClient
    public init(config: AppConfig, token: String) { http = DomainHTTPClient(config: config, token: token); files = AuthenticatedFileClient(config: config, token: token) }
    public static func path(_ value: String) throws -> String {
        guard !value.contains("\0"), !value.contains("\\"), value.count <= 1000 else { throw AppServiceError.message("Недопустимый путь FTP.") }
        let parts = value.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw AppServiceError.message("Недопустимый путь FTP.") }
        return "/" + parts.joined(separator: "/")
    }
    public func directory(_ path: String) async throws -> FTPDirectory {
        let path = try Self.path(path)
        let result = try http.decode(FTPDirectory.self, json: try await http.request("/api/v2/ftp/files", timeout: 60, query: [URLQueryItem(name: "path", value: path)]))
        guard result.path == path, Set(result.items.map(\.path)).count == result.items.count else { throw GsmFuelError.invalidResponse }
        for item in result.items {
            guard try Self.path(item.path) == item.path, item.path != "/", item.parent == path, !item.name.isEmpty, !item.name.contains("/"), !item.name.contains("\\"), (item.path as NSString).lastPathComponent == item.name else { throw GsmFuelError.invalidResponse }
        }
        return result
    }
    public func download(_ item: FTPItem, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let path = try Self.path(item.path)
        guard path != "/" else { throw AppServiceError.message("Выберите файл или папку.") }
        return try await files.download(path: item.isDirectory ? "/api/v2/ftp/download-folder" : "/api/v2/ftp/download", query: [URLQueryItem(name: "path", value: path)], progress: progress)
    }
}
