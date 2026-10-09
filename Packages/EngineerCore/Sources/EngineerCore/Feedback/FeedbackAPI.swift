import Foundation

public enum FeedbackWire {
    public static func decode<T: Decodable>(_ type: T.Type, json: Any?) throws -> T {
        guard let json else { throw GsmFuelError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom {
            let container = try $0.singleValueContainer(), value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Некорректная дата")
            }
            return date
        }
        return try decoder.decode(type, from: JSONSerialization.data(withJSONObject: json))
    }
}
public struct FeedbackSelectedImage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let data: Data
    public let fileName: String
    public init(id: String = UUID().uuidString, data: Data, fileName: String) {
        self.id = id; self.data = data; self.fileName = fileName
    }
}
public struct FeedbackPending: Codable, Equatable, Sendable {
    public var draft: FeedbackDraft
    public var images: [FeedbackSelectedImage]
    public var attempted: Bool
    public var device: FeedbackDeviceInfo?
    public init(draft: FeedbackDraft = .init(), images: [FeedbackSelectedImage] = [], attempted: Bool = false, device: FeedbackDeviceInfo? = nil) {
        self.draft = draft; self.images = images; self.attempted = attempted; self.device = device
    }
    public var hasContent: Bool { draft.hasContent || !images.isEmpty || !draft.reproductionSteps.isEmpty || !draft.expectedResult.isEmpty }
}
public struct FeedbackAPI {
    private let http: DomainHTTPClient
    private let config: AppConfig
    private let token: String
    public init(config: AppConfig, token: String, httpClient: HTTPClient? = nil) {
        self.config = config; self.token = token; http = DomainHTTPClient(config: config, token: token, httpClient: httpClient ?? .confidential)
    }
    public func messages(admin: Bool = false) async throws -> [FeedbackMessage] {
        struct Envelope: Decodable { let messages: [FeedbackMessage] }
        return try FeedbackWire.decode(Envelope.self, json: await http.request(admin ? "api/v2/admin/feedback" : "api/v2/feedback")).messages
    }
    private func message(_ json: Any?) throws -> FeedbackMessage {
        struct Envelope: Decodable { let message: FeedbackMessage }
        return try FeedbackWire.decode(Envelope.self, json: json).message
    }
    private func optional(_ text: String) -> Any {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? NSNull() : value
    }
    public func createDraft(_ draft: FeedbackDraft, device: FeedbackDeviceInfo) async throws -> FeedbackMessage {
        if let error = draft.validationMessage { throw AppServiceError.message(error) }
        return try message(await http.request("api/v2/feedback", method: "POST", body: [
            "clientRequestId": draft.clientRequestID.uuidString, "kind": draft.kind.rawValue,
            "title": draft.title.trimmingCharacters(in: .whitespacesAndNewlines), "message": draft.message.trimmingCharacters(in: .whitespacesAndNewlines),
            "reproductionSteps": optional(draft.reproductionSteps), "expectedResult": optional(draft.expectedResult),
            "areaCodes": draft.areas.map(\.rawValue).sorted(), "otherArea": draft.areas.contains(.other) ? optional(draft.otherArea) : NSNull(),
            "impact": draft.impact.rawValue, "frequency": draft.frequency.rawValue,
            "deviceInfo": try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)),
            "resubmittedFromId": draft.resubmittedFromID as Any? ?? NSNull()
        ]))
    }
    public func upload(_ image: FeedbackSelectedImage, reportID: String, check: () throws -> Void, progress: (Double) -> Void) async throws {
        guard !image.data.isEmpty, image.data.count <= 20 * 1024 * 1024, !image.fileName.isEmpty, image.fileName.count <= 240,
              (16...64).contains(image.id.count), image.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw AppServiceError.message("Некорректное вложение.") }
        let chunkSize = 512 * 1024, count = (image.data.count + chunkSize - 1) / chunkSize, uploadID = UUID().uuidString
        let path = "api/v2/feedback/" + (try DomainHTTPClient.id(reportID)) + "/attachments/chunk"
        for index in 0..<count {
            try check()
            let offset = index * chunkSize, chunk = image.data.subdata(in: offset..<min(offset + chunkSize, image.data.count))
            _ = try await http.request(path, method: "POST", body: ["uploadId": uploadID, "imageId": image.id, "fileName": image.fileName, "chunkIndex": index, "totalChunks": count, "chunkBase64": chunk.base64EncodedString()])
            try check(); progress(Double(index + 1) / Double(count))
        }
    }
    public func submit(id: String) async throws -> FeedbackMessage {
        try message(await http.request("api/v2/feedback/" + DomainHTTPClient.id(id) + "/submit", method: "POST", body: [:]))
    }
    public func add(text: String, id: String) async throws -> FeedbackMessage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...4000).contains(text.count) else { throw AppServiceError.message("Дополнение должно содержать от 3 до 4000 символов.") }
        return try message(await http.request("api/v2/feedback/" + DomainHTTPClient.id(id) + "/additions", method: "POST", body: ["text": text]))
    }
    public func update(id: String, status: FeedbackStatus, priority: FeedbackPriority, note: String) async throws -> FeedbackMessage {
        guard status != .draft, note.trimmingCharacters(in: .whitespacesAndNewlines).count <= 4000 else { throw AppServiceError.message("Проверьте статус и длину заметки.") }
        return try message(await http.request("api/v2/admin/feedback/" + DomainHTTPClient.id(id), method: "PATCH", body: ["status": status.rawValue, "priority": priority.rawValue, "note": optional(note)]))
    }
    public func retryEmail(id: String) async throws { _ = try await http.request("api/v2/admin/feedback/" + DomainHTTPClient.id(id) + "/retry-email", method: "POST", body: [:]) }
    public func attachment(reportID: String, attachmentID: String, admin: Bool = false) async throws -> URL {
        try await AuthenticatedFileClient(config: config, token: token).download(path: "api/v2/" + (admin ? "admin/feedback/" : "feedback/") + DomainHTTPClient.id(reportID) + "/attachments/" + DomainHTTPClient.id(attachmentID), maximumBytes: 4 * 1024 * 1024)
    }
}

public struct FeedbackDraftReference: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let attempted: Bool
    public let updatedAt: Date
}
