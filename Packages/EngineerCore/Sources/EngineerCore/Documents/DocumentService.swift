import Foundation

public struct DocumentService {
    private let http: DomainHTTPClient
    private let files: AuthenticatedFileClient
    public init(config: AppConfig, token: String) { http = DomainHTTPClient(config: config, token: token); files = AuthenticatedFileClient(config: config, token: token) }
    public func list(_ collection: DocumentCollection) async throws -> [ServerDocument] {
        let json: Any?
        if case .vehicle(let vehicleID) = collection {
            let raw = try await http.request("/api/v2/vehicles") as? [String: Any]
            guard let vehicles = raw?["vehicles"] as? [[String: Any]], let vehicle = vehicles.first(where: { $0["id"] as? String == vehicleID }) else { throw AppServiceError.http(status: 404, fallback: "Автомобиль не найден") }
            json = vehicle["documents"] ?? []
        } else { json = (try await http.request(collection.path) as? [String: Any])?["documents"] }
        let result = try http.decode([ServerDocument].self, json: json)
        guard Set(result.map(\.id)).count == result.count else { throw GsmFuelError.invalidResponse }
        for value in result { try validate(value, collection) }
        return result
    }
    private func validate(_ value: ServerDocument, _ collection: DocumentCollection) throws {
        _ = try DomainHTTPClient.id(value.id)
        guard !value.fileName.isEmpty, value.sizeBytes >= 0, value.sizeBytes <= ServerDocument.maximumBytes, collection.allowedMIMETypes.contains(value.mimeType) else { throw GsmFuelError.invalidResponse }
        switch collection {
        case .work: guard value.category != nil, value.title != nil else { throw GsmFuelError.invalidResponse }
        case .vehicle: guard value.kind != nil else { throw GsmFuelError.invalidResponse }
        case .salary: guard let month = value.month, ServerDocument.validMonth(month) else { throw GsmFuelError.invalidResponse }
        }
    }
    private func path(_ value: ServerDocument, _ collection: DocumentCollection) throws -> String {
        let component = collection == .salary ? value.month ?? "" : value.id
        if collection == .salary, !ServerDocument.validMonth(component) { throw GsmFuelError.invalidResponse }
        return try collection.path + "/" + DomainHTTPClient.id(component)
    }
    // check() runs on both sides of every chunk suspension, including salary grant revocation.
    @MainActor public func upload(_ upload: DocumentUpload, collection: DocumentCollection, replacing: ServerDocument?, check: () throws -> Void, progress: (Double) -> Void) async throws -> ServerDocument {
        try upload.validate(for: collection); try check()
        let uploadID = UUID().uuidString, chunkSize = 512 * 1024
        let total = (upload.data.count + chunkSize - 1) / chunkSize
        let root = try collection.path
        let endpoint = collection == .salary ? root + "/" + upload.month + "/chunk" : root + "/chunk"
        for index in 0..<total {
            try check()
            var body: [String: Any] = ["uploadId": uploadID, "fileName": upload.fileName, "mimeType": upload.mimeType, "chunkIndex": index, "totalChunks": total,
                                       "chunkBase64": upload.data.subdata(in: index * chunkSize..<min((index + 1) * chunkSize, upload.data.count)).base64EncodedString()]
            switch collection {
            case .work: body["documentId"] = replacing?.id ?? upload.id; body["category"] = upload.category.rawValue; body["title"] = upload.title.trimmingCharacters(in: .whitespacesAndNewlines)
            case .vehicle: body["documentId"] = replacing?.id ?? upload.id; body["kind"] = upload.kind.rawValue
            case .salary: break
            }
            let response = try await http.request(endpoint, method: "POST", body: body, timeout: 120) as? [String: Any]
            try check()
            if index == total - 1 {
                guard response?["complete"] as? Bool == true else { throw GsmFuelError.invalidResponse }
                let value = try http.decode(ServerDocument.self, json: response?["document"]); try validate(value, collection)
                guard collection == .salary ? value.month == upload.month : value.id == (replacing?.id ?? upload.id) else { throw GsmFuelError.invalidResponse }
                progress(1); return value
            }
            guard response?["complete"] as? Bool == false, response?["received"] as? Int == index + 1, response?["totalChunks"] as? Int == total else { throw GsmFuelError.invalidResponse }
            progress(Double(index + 1) / Double(total))
        }
        throw GsmFuelError.invalidResponse
    }
    public func update(_ value: ServerDocument, category: WorkDocumentCategory, title: String) async throws -> ServerDocument {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw AppServiceError.message("Название должно содержать от 1 до 200 символов.") }
        let result = try http.decode(ServerDocument.self, json: (try await http.request(path(value, .work), method: "PATCH", body: ["category": category.rawValue, "title": title]) as? [String: Any])?["document"])
        try validate(result, .work); guard result.id == value.id else { throw GsmFuelError.invalidResponse }; return result
    }
    public func delete(_ value: ServerDocument, collection: DocumentCollection) async throws { _ = try await http.request(path(value, collection), method: "DELETE") }
    public func download(_ value: ServerDocument, collection: DocumentCollection) async throws -> URL {
        try await files.download(path: path(value, collection), maximumBytes: Int64(ServerDocument.maximumBytes))
    }
}
