import Foundation

public struct AssistantAPI {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration, delegate: ConfidentialRequestRedirectBlocker(), delegateQueue: nil)
    }()

    private let origin: URL?
    private let authToken: String?

    public init(config: AppConfig, authToken: String?) {
        origin = try? AppConfig.validatedURL(config.lumaWorkAPIOrigin)
        self.authToken = authToken
    }

    public func run(
        message: String,
        conversationID: UUID,
        requestID: UUID = UUID(),
        currentScreen: String? = nil,
        image: AssistantPreparedImagePayload? = nil,
        document: AssistantPreparedDocumentPayload? = nil,
        toolResults: [AssistantAPIToolResult]? = nil
    ) async throws -> AssistantAPIRunEnvelope {
        guard let origin else {
            throw AppServiceError.message("API приложения не настроен.")
        }
        guard let authToken, !authToken.isEmpty else {
            throw AppServiceError.message("Войдите в приложение заново.")
        }

        var request = URLRequest(url: origin.appendingPathComponent("api/v2/assistant/runs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(AssistantAPIRunRequest(
            requestID: requestID,
            conversationID: conversationID,
            message: message,
            currentScreen: currentScreen,
            image: image.map(AssistantAPIImage.init),
            document: document.map(AssistantAPIDocument.init),
            toolResults: toolResults
        ))

        // Вопрос и изображение намеренно не передаются в общий NetworkDiagnostics.
        try Task.checkCancellation()
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(AssistantAPIError.self, from: data)
            let message = envelope?.message ?? "Помощник временно недоступен."
            if envelope?.error == "ASSISTANT_CONVERSATION_TOKEN_LIMIT" {
                return AssistantAPIRunEnvelope(
                    result: .conversationFull(message, status: envelope?.conversation),
                    messageTimestamps: nil
                )
            }
            throw AppServiceError.http(status: httpResponse.statusCode, fallback: message)
        }

        let envelope = try JSONDecoder().decode(AssistantAPIResponse.self, from: data)
        return AssistantAPIRunEnvelope(
            result: try Self.runResult(from: envelope),
            messageTimestamps: envelope.messageTimestamps
        )
    }

    public func runStreaming(
        message: String,
        conversationID: UUID,
        requestID: UUID = UUID(),
        currentScreen: String? = nil,
        image: AssistantPreparedImagePayload? = nil,
        document: AssistantPreparedDocumentPayload? = nil,
        toolResults: [AssistantAPIToolResult]? = nil,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> AssistantAPIRunEnvelope {
        guard let origin else { throw AppServiceError.message("API приложения не настроен.") }
        guard let authToken, !authToken.isEmpty else { throw AppServiceError.message("Войдите в приложение заново.") }

        var request = URLRequest(url: origin.appendingPathComponent("api/v2/assistant/runs/stream"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(AssistantAPIRunRequest(
            requestID: requestID,
            conversationID: conversationID,
            message: message,
            currentScreen: currentScreen,
            image: image.map(AssistantAPIImage.init),
            document: document.map(AssistantAPIDocument.init),
            toolResults: toolResults
        ))

        try Task.checkCancellation()
        let (bytes, response) = try await Self.session.bytes(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            var errorData = Data()
            for try await byte in bytes { try Task.checkCancellation(); guard errorData.count < 64 * 1024 else { break }; errorData.append(byte) }
            let envelope = try? JSONDecoder().decode(AssistantAPIError.self, from: errorData)
            if envelope?.error == "ASSISTANT_CONVERSATION_TOKEN_LIMIT" {
                return AssistantAPIRunEnvelope(
                    result: .conversationFull(
                        envelope?.message ?? "Лимит этого чата исчерпан.",
                        status: envelope?.conversation
                    ),
                    messageTimestamps: nil
                )
            }
            throw AppServiceError.http(
                status: httpResponse.statusCode,
                fallback: envelope?.message ?? "Помощник временно недоступен."
            )
        }

        var eventName = ""
        var dataLines: [String] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= 1024 * 1024, dataLines.reduce(0, { $0 + $1.utf8.count }) <= 2 * 1024 * 1024 else { throw AppServiceError.message("Ответ помощника превышает допустимый размер.") }
            if line.isEmpty {
                if let result = try await Self.consumeStreamEvent(
                    name: eventName,
                    data: dataLines.joined(separator: "\n"),
                    onDelta: onDelta
                ) {
                    return result
                }
                eventName = ""
                dataLines = []
            } else if line.hasPrefix("event:") {
                eventName = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if let result = try await Self.consumeStreamEvent(
            name: eventName,
            data: dataLines.joined(separator: "\n"),
            onDelta: onDelta
        ) {
            return result
        }
        throw AppServiceError.message("Поток ответа завершился раньше времени.")
    }

    private static func runResult(from envelope: AssistantAPIResponse) throws -> AssistantAPIRunResult {
        switch envelope.kind {
        case "blocked":
            return .blocked(
                envelope.text ?? "Запрос не относится к рабочим задачам.",
                status: envelope.conversation
            )
        case "answer":
            guard let text = envelope.text, !text.isEmpty else {
                throw AppServiceError.message("Помощник вернул пустой ответ.")
            }
            return .answer(
                text,
                truncated: envelope.truncated ?? false,
                sources: envelope.sources ?? [],
                knowledge: envelope.knowledge,
                contextCompacted: envelope.contextCompacted ?? false,
                status: envelope.conversation
            )
        case "tool_request":
            return .toolRequest(
                envelope.requests ?? [],
                contextCompacted: envelope.contextCompacted ?? false,
                status: envelope.conversation
            )
        default:
            guard let text = envelope.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw AppServiceError.message("Сервер вернул неизвестный ответ помощника.")
            }
            return .answer(
                text,
                truncated: envelope.truncated ?? false,
                sources: envelope.sources ?? [],
                knowledge: envelope.knowledge,
                contextCompacted: envelope.contextCompacted ?? false,
                status: envelope.conversation
            )
        }
    }

    private static func consumeStreamEvent(
        name: String,
        data: String,
        onDelta: @escaping @MainActor (String) -> Void
    ) async throws -> AssistantAPIRunEnvelope? {
        guard !data.isEmpty else { return nil }
        switch name {
        case "delta":
            if let delta = try? JSONDecoder().decode(AssistantAPIStreamDelta.self, from: Data(data.utf8)),
               !delta.text.isEmpty {
                await onDelta(delta.text)
            }
            return nil
        case "done":
            let envelope = try JSONDecoder().decode(AssistantAPIResponse.self, from: Data(data.utf8))
            return AssistantAPIRunEnvelope(
                result: try runResult(from: envelope),
                messageTimestamps: envelope.messageTimestamps
            )
        case "error":
            let envelope = try? JSONDecoder().decode(AssistantAPIError.self, from: Data(data.utf8))
            if envelope?.error == "ASSISTANT_CONVERSATION_TOKEN_LIMIT" {
                return AssistantAPIRunEnvelope(
                    result: .conversationFull(
                        envelope?.message ?? "Лимит этого чата исчерпан.",
                        status: envelope?.conversation
                    ),
                    messageTimestamps: nil
                )
            }
            throw AppServiceError.message(envelope?.message ?? "Помощник временно недоступен.")
        default:
            return nil
        }
    }

    public func conversations(limit: Int = 30, cursor: String? = nil) async throws -> AssistantAPIConversationPage {
        let url = try endpoint(
            "api/v2/assistant/conversations",
            queryItems: [
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
                cursor.map { URLQueryItem(name: "cursor", value: $0) }
            ].compactMap { $0 }
        )
        return try await get(url, as: AssistantAPIConversationPage.self)
    }

    public func submitKnowledgeFeedback(
        claimID: String,
        answerTraceID: String,
        feedback: AssistantKnowledgeFeedback,
        conversationID: UUID,
        clientRequestID: UUID = UUID()
    ) async throws {
        guard let origin else { throw AppServiceError.message("API приложения не настроен.") }
        guard let authToken, !authToken.isEmpty else { throw AppServiceError.message("Войдите в приложение заново.") }

        var request = URLRequest(url: origin.appendingPathComponent("api/v2/knowledge/feedback"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(AssistantKnowledgeFeedbackRequest(
            claimID: claimID,
            answerTraceID: answerTraceID,
            feedback: feedback.rawValue,
            source: feedback == .support ? "lumawork_like" : "lumawork_dislike",
            clientRequestID: clientRequestID.uuidString.lowercased(),
            conversationID: conversationID.uuidString.lowercased()
        ))
        try Task.checkCancellation()
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let envelope = try? JSONDecoder().decode(AssistantAPIError.self, from: data)
            throw AppServiceError.http(
                status: httpResponse.statusCode,
                fallback: envelope?.message ?? "Не удалось сохранить подтверждение."
            )
        }
    }

    public func messages(
        conversationID: UUID,
        limit: Int = 60,
        cursor: String? = nil
    ) async throws -> AssistantAPIMessagePage {
        let url = try endpoint(
            "api/v2/assistant/conversations/\(conversationID.uuidString.lowercased())/messages",
            queryItems: [
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
                cursor.map { URLQueryItem(name: "cursor", value: $0) }
            ].compactMap { $0 }
        )
        return try await get(url, as: AssistantAPIMessagePage.self)
    }

    public func deleteConversation(_ conversationID: UUID) async throws {
        let url = try endpoint("api/v2/assistant/conversations/\(conversationID.uuidString.lowercased())")
        var request = try authorizedRequest(url: url)
        request.httpMethod = "DELETE"
        try Task.checkCancellation()
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        try validate(response: response, data: data, expectedStatus: 204)
    }

    public func renameConversation(_ conversationID: UUID, title: String) async throws {
        let url = try endpoint("api/v2/assistant/conversations/\(conversationID.uuidString.lowercased())")
        var request = try authorizedRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["title": title])
        try Task.checkCancellation()
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        try validate(response: response, data: data)
    }

    private func endpoint(_ path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard let origin else {
            throw AppServiceError.message("API приложения не настроен.")
        }
        let url = origin.appendingPathComponent(path)
        guard !queryItems.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AppServiceError.message("Не удалось собрать адрес помощника.")
        }
        components.queryItems = queryItems
        guard let result = components.url else {
            throw AppServiceError.message("Не удалось собрать адрес помощника.")
        }
        return result
    }

    private func get<Response: Decodable>(_ url: URL, as type: Response.Type) async throws -> Response {
        var request = try authorizedRequest(url: url)
        request.httpMethod = "GET"
        try Task.checkCancellation()
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        try validate(response: response, data: data)
        return try JSONDecoder().decode(type, from: data)
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        guard let authToken, !authToken.isEmpty else {
            throw AppServiceError.message("Войдите в приложение заново.")
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(response: URLResponse, data: Data, expectedStatus: Int? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Сервер вернул неизвестный ответ.")
        }
        let isSuccess = expectedStatus.map { httpResponse.statusCode == $0 }
            ?? (200 ..< 300).contains(httpResponse.statusCode)
        guard isSuccess else {
            let message = (try? JSONDecoder().decode(AssistantAPIError.self, from: data).message)
                ?? "Помощник временно недоступен."
            throw AppServiceError.http(status: httpResponse.statusCode, fallback: message)
        }
    }
}

public enum AssistantAPIRunResult {
    case blocked(String, status: AssistantAPIConversationStatus?)
    case answer(
        String,
        truncated: Bool,
        sources: [String],
        knowledge: AssistantAPIKnowledgeReference?,
        contextCompacted: Bool,
        status: AssistantAPIConversationStatus?
    )
    case toolRequest(
        [AssistantAPIToolRequest],
        contextCompacted: Bool,
        status: AssistantAPIConversationStatus?
    )
    case conversationFull(String, status: AssistantAPIConversationStatus?)
}

public struct AssistantAPIRunEnvelope {
    public let result: AssistantAPIRunResult
    public let messageTimestamps: AssistantAPIMessageTimestamps?
}

public enum AssistantKnowledgeFeedback: String, Codable, Sendable {
    case support
    case contradict
}

public struct AssistantAPIKnowledgeReference: Codable, Equatable, Sendable {
    public let answerTraceId: String
    public let claims: [AssistantAPIKnowledgeClaim]

    public var primaryClaim: AssistantAPIKnowledgeClaim? {
        let primary = claims.filter { $0.role == "primary" }
        return primary.count == 1 ? primary[0] : nil
    }

    public var jsonValue: AssistantJSONValue {
        .object([
            "answerTraceId": .string(answerTraceId),
            "claims": .array(claims.map(\.jsonValue))
        ])
    }
}

public struct AssistantAPIKnowledgeClaim: Codable, Equatable, Sendable {
    public let id: String
    public let state: String
    public let role: String

    public var jsonValue: AssistantJSONValue {
        .object(["id": .string(id), "state": .string(state), "role": .string(role)])
    }
}

public struct AssistantAPIMessageTimestamps: Decodable, Equatable {
    public let user: String?
    public let assistant: String?
}

public struct AssistantAPIToolRequest: Decodable, Equatable {
    public let name: String
    public let arguments: [String: AssistantJSONValue]
}

public struct AssistantAPIToolResult: Codable, Sendable {
    public let name: String
    public let payload: AssistantJSONValue
}

public struct AssistantAPIConversation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let preview: String
    public let lastMessageAt: String
    public let createdAt: String
    public let usedTokens: Int?
    public let tokenLimit: Int?
    public let isFull: Bool?
    public let contextTokens: Int?
    public let compressionThreshold: Int?
    public let compactions: Int?
    public let willCompressOnNextRun: Bool?

    public init(
        id: UUID,
        title: String,
        preview: String,
        lastMessageAt: String,
        createdAt: String,
        usedTokens: Int? = nil,
        tokenLimit: Int? = nil,
        isFull: Bool? = nil,
        contextTokens: Int? = nil,
        compressionThreshold: Int? = nil,
        compactions: Int? = nil,
        willCompressOnNextRun: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.lastMessageAt = lastMessageAt
        self.createdAt = createdAt
        self.usedTokens = usedTokens
        self.tokenLimit = tokenLimit
        self.isFull = isFull
        self.contextTokens = contextTokens
        self.compressionThreshold = compressionThreshold
        self.compactions = compactions
        self.willCompressOnNextRun = willCompressOnNextRun
    }

    public func updating(title: String) -> Self {
        Self(
            id: id,
            title: title,
            preview: preview,
            lastMessageAt: lastMessageAt,
            createdAt: createdAt,
            usedTokens: usedTokens,
            tokenLimit: tokenLimit,
            isFull: isFull,
            contextTokens: contextTokens,
            compressionThreshold: compressionThreshold,
            compactions: compactions,
            willCompressOnNextRun: willCompressOnNextRun
        )
    }

    public func updating(status: AssistantAPIConversationStatus) -> Self {
        Self(
            id: id,
            title: title,
            preview: preview,
            lastMessageAt: lastMessageAt,
            createdAt: createdAt,
            usedTokens: status.usedTokens,
            tokenLimit: status.tokenLimit,
            isFull: status.isFull,
            contextTokens: status.contextTokens,
            compressionThreshold: status.compressionThreshold,
            compactions: status.compactions,
            willCompressOnNextRun: status.willCompressOnNextRun
        )
    }
}

public struct AssistantAPIConversationStatus: Codable, Equatable, Sendable {
    public let usedTokens: Int
    public let tokenLimit: Int
    public let isFull: Bool
    public let contextTokens: Int
    public let compressionThreshold: Int
    public let compactions: Int
    public let willCompressOnNextRun: Bool
}

public struct AssistantAPIMessage: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let requestId: String?
    public let role: String
    public let content: String
    public let attachmentMeta: AssistantJSONValue?
    public let createdAt: String
}

public struct AssistantAPIConversationPage: Decodable {
    public let conversations: [AssistantAPIConversation]
    public let nextCursor: String?
}

public struct AssistantAPIMessagePage: Decodable {
    public let messages: [AssistantAPIMessage]
    public let nextCursor: String?
    public let conversation: AssistantAPIConversationStatus?
}

public enum AssistantJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AssistantJSONValue])
    case array([AssistantJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AssistantJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([AssistantJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private struct AssistantAPIRunRequest: Encodable {
    let requestID: UUID
    let conversationID: UUID
    let message: String
    let currentScreen: String?
    let image: AssistantAPIImage?
    let document: AssistantAPIDocument?
    let toolResults: [AssistantAPIToolResult]?

    private enum CodingKeys: String, CodingKey {
        case requestID = "requestId"
        case conversationID = "conversationId"
        case message
        case currentScreen
        case image
        case document
        case toolResults
    }
}

private struct AssistantAPIDocument: Encodable {
    let fileName: String
    let mimeType: String
    let text: String
    let extraction: String
    let sourceBytes: Int
    let wasTruncated: Bool
    let pageCount: Int?
    let sheetNames: [String]
    let rawBase64: String?

    init(_ document: AssistantPreparedDocumentPayload) {
        fileName = document.fileName
        mimeType = document.mimeType
        text = document.text
        extraction = document.extraction
        sourceBytes = document.sourceBytes
        wasTruncated = document.wasTruncated
        pageCount = document.pageCount
        sheetNames = document.sheetNames
        rawBase64 = document.rawData?.base64EncodedString()
    }
}

private struct AssistantAPIImage: Encodable {
    let mimeType: String
    let base64: String

    init(_ image: AssistantPreparedImagePayload) {
        mimeType = image.mimeType
        base64 = image.data.base64EncodedString()
    }
}

private struct AssistantAPIResponse: Decodable {
    let kind: String
    let text: String?
    let requests: [AssistantAPIToolRequest]?
    let truncated: Bool?
    let sources: [String]?
    let knowledge: AssistantAPIKnowledgeReference?
    let contextCompacted: Bool?
    let conversation: AssistantAPIConversationStatus?
    let messageTimestamps: AssistantAPIMessageTimestamps?

    private enum CodingKeys: String, CodingKey {
        case kind, text, requests, truncated, sources, knowledge, contextCompacted, conversation, messageTimestamps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        text = try? container.decode(String.self, forKey: .text)
        requests = try? container.decode([AssistantAPIToolRequest].self, forKey: .requests)
        truncated = try? container.decode(Bool.self, forKey: .truncated)
        sources = try? container.decode([String].self, forKey: .sources)
        knowledge = try? container.decode(AssistantAPIKnowledgeReference.self, forKey: .knowledge)
        contextCompacted = try? container.decode(Bool.self, forKey: .contextCompacted)
        conversation = try? container.decode(AssistantAPIConversationStatus.self, forKey: .conversation)
        messageTimestamps = try? container.decode(AssistantAPIMessageTimestamps.self, forKey: .messageTimestamps)
    }
}

private struct AssistantKnowledgeFeedbackRequest: Encodable {
    let claimID: String
    let answerTraceID: String
    let feedback: String
    let source: String
    let clientRequestID: String
    let conversationID: String

    enum CodingKeys: String, CodingKey {
        case claimID = "claimId"
        case answerTraceID = "answerTraceId"
        case feedback, source
        case clientRequestID = "clientRequestId"
        case conversationID = "conversationId"
    }
}

private struct AssistantAPIStreamDelta: Decodable {
    let text: String
}

private struct AssistantAPIError: Decodable {
    let error: String?
    let message: String?
    let conversation: AssistantAPIConversationStatus?
}
