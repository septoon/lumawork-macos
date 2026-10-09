import Foundation
import CryptoKit

public struct FuelImportService {
    private let client: DomainHTTPClient
    public init(config: AppConfig, token: String) { client = DomainHTTPClient(config: config, token: token) }
    private func files(_ uploads: [FuelImportUpload]) throws -> [[String: String]] {
        guard (1...20).contains(uploads.count) else { throw AppServiceError.message("Выберите от 1 до 20 XLSX-файлов.") }
        var size = 0
        var hashes = Set<String>()
        return try uploads.map {
            guard !$0.fileName.isEmpty, $0.fileName.count <= 240, $0.fileName.lowercased().hasSuffix(".xlsx"),
                  let data = Data(base64Encoded: $0.dataBase64), !data.isEmpty, data.count <= 6 * 1024 * 1024 else { throw AppServiceError.message("Размер каждого XLSX должен быть от 1 байта до 6 МБ.") }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hashes.insert(hash).inserted else { throw AppServiceError.message("Выбраны одинаковые отчёты. Оставьте один экземпляр каждого файла.") }
            size += data.count
            guard size <= 7 * 1024 * 1024 else { throw AppServiceError.message("Общий размер отчётов не должен превышать 7 МБ.") }
            return ["fileName": $0.fileName, "dataBase64": $0.dataBase64]
        }
    }
    public static func fingerprint(_ uploads: [FuelImportUpload]) -> String {
        let parts = uploads.map { upload in
            upload.fileName + ":" + SHA256.hash(data: Data(base64Encoded: upload.dataBase64) ?? Data()).map { String(format: "%02x", $0) }.joined()
        }.sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func preview(_ uploads: [FuelImportUpload]) async throws -> [FuelImportPreviewItem] {
        let response = try await client.request("api/v2/fuel/imports/preview", method: "POST", body: ["files": try files(uploads)], timeout: 60)
        let items = try client.decode(PreviewResponse.self, json: response).items
        guard items.count == uploads.count, Set(items.map(\.id)).count == items.count else { throw GsmFuelError.invalidResponse }
        var remaining = uploads
        for item in items {
            guard let index = remaining.firstIndex(where: { upload in
                guard upload.fileName == item.fileName else { return false }
                if item.status == .error && item.fileHash.isEmpty { return true }
                let hash = SHA256.hash(data: Data(base64Encoded: upload.dataBase64) ?? Data()).map { String(format: "%02x", $0) }.joined()
                return hash == item.fileHash
            }) else { throw GsmFuelError.invalidResponse }
            remaining.remove(at: index)
            guard Set(item.entries.map(\.row)).count == item.entries.count, item.totalCost.isFinite, item.totalLiters.isFinite else { throw GsmFuelError.invalidResponse }
        }
        return items
    }
    public static func correctionPayload(_ correction: FuelImportCorrection) throws -> [String: Any] {
        guard correction.fileHash.count == 64, correction.fileHash.allSatisfy({ "0123456789abcdef".contains($0) }), correction.entries.count <= 100,
              Set(correction.entries.map(\.row)).count == correction.entries.count,
              correction.period.map(GsmWire.isValidMonth) ?? true else { throw AppServiceError.message("Проверьте период и строки исправлений (не более 100).") }
        for entry in correction.entries {
            guard entry.row > 0, entry.fuelType.trimmingCharacters(in: .whitespacesAndNewlines).count <= 80 else { throw GsmFuelError.invalidResponse }
            if !entry.date.isEmpty, (entry.date.count != 10 || RequestsPolicy.date(entry.date) == nil) { throw AppServiceError.message("Дата заправки должна быть в формате YYYY-MM-DD.") }
            for (raw, maximum) in [(entry.liters, 10_000.0), (entry.cost, 10_000_000.0)] where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let number = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")), number.isFinite, (0...maximum).contains(number) else { throw AppServiceError.message("Проверьте литры и стоимость заправки.") }
            }
        }
        return correction.dictionary
    }
    public func commit(_ uploads: [FuelImportUpload], replacing ids: Set<String>, corrections: [FuelImportCorrection]) async throws -> FuelImportCommitResponse {
        guard ids.count <= 20, corrections.count <= 20 else { throw GsmFuelError.invalidResponse }
        let body: [String: Any] = ["files": try files(uploads), "replaceImportIds": Array(ids), "corrections": try corrections.map(Self.correctionPayload)]
        return try client.decode(FuelImportCommitResponse.self, json: await client.request("api/v2/fuel/imports/commit", method: "POST", body: body, timeout: 60))
    }
    private struct PreviewResponse: Decodable { let items: [FuelImportPreviewItem] }
}
