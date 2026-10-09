import Foundation

struct ArchiveCursor: Codable, Hashable, Comparable, Sendable {
    var updatedAt: String
    var sysID: String
    init?(_ record: SimpleOneRequestRecord) {
        guard let version = record.sysUpdatedAt, !version.isEmpty, !record.sysID.isEmpty else { return nil }
        updatedAt = version; sysID = record.sysID
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.updatedAt == rhs.updatedAt ? lhs.sysID < rhs.sysID : lhs.updatedAt < rhs.updatedAt }
}

public struct RequestsArchivePage: Sendable {
    public var records: [SimpleOneRequestRecord]
    public var total: Int?
    public var hasMore: Bool
    public init(records: [SimpleOneRequestRecord], total: Int?, hasMore: Bool) { self.records = records; self.total = total; self.hasMore = hasMore }
}

public struct RequestsArchiveProgress: Sendable {
    public var loaded: Int
    public var total: Int?
    public var canResume: Bool
}

struct ArchiveVersion: Codable, Equatable, Sendable {
    var id: String
    var version: String
    init(_ record: SimpleOneRequestRecord) { id = record.sysID; version = record.sysUpdatedAt ?? "" }
}
struct ArchiveMetadata: Codable, Sendable {
    var number: String
    var version: String
    var excluded: Bool
}
struct ArchiveSyncState: Codable, Sendable {
    var query: String
    var watermark: ArchiveCursor?
    var metadata: [String: ArchiveMetadata]
    var trusted: Bool
}
struct ArchiveCheckpoint: Codable, Sendable {
    var query: String
    var nextPage = 1
    var total: Int?
    var head: [ArchiveVersion] = []
    var previousPage: [ArchiveVersion] = []
    var records: [String: SimpleOneRequestRecord] = [:]
    var metadata: [String: ArchiveMetadata] = [:]
    var watermark: ArchiveCursor?
    var previousCursor: ArchiveCursor?
    var incremental = false
    var reachedBoundary = false
    var versionsValid = true
}
enum ArchiveSyncError: LocalizedError {
    case changed, incomplete, identity
    var errorDescription: String? {
        switch self {
        case .changed: "Архив изменился во время загрузки. Прогресс сброшен; повторите обновление."
        case .incomplete: "SimpleOne вернул неполный или повторяющийся архив. Кеш сохранён; повторите обновление."
        case .identity: "SimpleOne вернул конфликт номера заявки и sys_id. Кеш сохранён."
        }
    }
}
