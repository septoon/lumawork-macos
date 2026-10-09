import Foundation
import Observation

public struct WikiSearchResponse: Decodable {
    public let query: String
    public let snapshotId: String?
    public let results: [WikiSearchResult]
}

public struct WikiHealthResponse: Codable, Sendable {
    public let snapshotId: String?
    public let contentVersion: String?
    public let articles: Int?
}

public struct WikiSearchPage: Codable, Sendable {
    public let snapshotID: String?
    public let results: [WikiSearchResult]
}

public struct WikiSearchResult: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let section: String
    public let sourceUrl: String
    public let score: Int
    public let excerpt: String
    public let hasPdf: Bool?
    public let pdfUrl: String?
}

public struct WikiArticle: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let section: String
    public let sourceUrl: String
    public let relativePath: String?
    public let hasPdf: Bool?
    public let pdfUrl: String?
    public let pdfRelativePath: String?
    public let content: String
    public let truncated: Bool?
    public let contentLength: Int?
    public let snapshotId: String?
}

private struct WikiSearchSnapshot: Codable {
    let query: String
    let snapshotID: String?
    let results: [WikiSearchResult]
}

public struct WikiAPI {
    private let origin: URL
    private let token: String?
    private let session: URLSession

    public init(config: AppConfig, token: String? = nil, session: URLSession? = nil) {
        self.origin = AppConfig.configuredURL(config.wikiAPIOrigin)
        self.token = Self.nonEmpty((token ?? config.wikiAPIToken)?.trimmingCharacters(in: .whitespacesAndNewlines))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: configuration, delegate: ConfidentialRequestRedirectBlocker(), delegateQueue: nil)
    }

    public func health() async throws -> WikiHealthResponse {
        try await request(origin.appendingPathComponent("health"), requiresToken: false)
    }

    public func search(query: String, limit: Int = 10) async throws -> WikiSearchPage {
        guard token != nil else {
            throw AppServiceError.message("Не задан WIKI_API_TOKEN.")
        }

        var components = URLComponents(url: origin.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]

        guard let url = components?.url else {
            throw AppServiceError.message("Не удалось собрать адрес поиска Wiki.")
        }

        let response: WikiSearchResponse = try await request(url)
        return WikiSearchPage(snapshotID: response.snapshotId, results: response.results)
    }

    public func article(id: String, maxChars: Int = 90000) async throws -> WikiArticle {
        guard token != nil else {
            throw AppServiceError.message("Не задан WIKI_API_TOKEN.")
        }

        var components = URLComponents(
            url: origin.appendingPathComponent("article").appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "maxChars", value: String(maxChars))
        ]

        guard let url = components?.url else {
            throw AppServiceError.message("Не удалось собрать адрес статьи Wiki.")
        }

        return try await request(url)
    }

    private func pdfURL(for id: String) -> URL {
        let url = origin.appendingPathComponent("pdf").appendingPathComponent(id)
        guard let token else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        return components?.url ?? url
    }

    public func isPDFAvailable(id: String) async -> Bool {
        var request = URLRequest(url: pdfURL(for: id))
        request.httpMethod = "HEAD"
        request.timeoutInterval = 12
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200 ..< 300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    public func downloadPDF(id: String) async throws -> URL {
        guard let token else { throw AppServiceError.message("Не задан WIKI_API_TOKEN.") }
        let fileConfig = AppConfig(lumaWorkAPIOrigin: origin.absoluteString)
        return try await AuthenticatedFileClient(config: fileConfig, token: token).download(path: "pdf/" + id, query: [URLQueryItem(name: "token", value: token)], maximumBytes: 20 * 1024 * 1024)
    }

    private func request<Response: Decodable>(
        _ url: URL,
        requiresToken: Bool = true
    ) async throws -> Response {
        guard !origin.isFileURL else { throw AppServiceError.message("Не настроен адрес Wiki.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if requiresToken, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            switch AppErrorClassification.classification(for: error) {
            case .cancellation:
                throw CancellationError()
            case .network:
                throw error
            case .domain:
                throw AppServiceError.message("Wiki временно недоступна.")
            }
        }

        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppServiceError.message("Wiki вернула неизвестный ответ.")
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw AppServiceError.http(status: httpResponse.statusCode, fallback: backendMessage(from: data) ?? "Wiki временно недоступна.")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func backendMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object["message"] as? String) ?? (object["error"] as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
