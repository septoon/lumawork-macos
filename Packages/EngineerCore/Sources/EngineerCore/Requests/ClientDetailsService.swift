import Foundation

public struct CompanyLookupCompany: Codable, Sendable {
    public let name: String
    public let fullName: String?
    public let inn: String
    public let kpp: String?
    public let ogrn: String?
    public let status: String?
    public let legalForm: String?
    public let directorName: String?
    public let directorPost: String?
    public let address: String?
    public let okved: String?
    public let okvedName: String?
    public let registrationDate: String?
}

public struct ClientDetailsService {
    private let config: AppConfig
    private let token: String
    private let client: HTTPClient
    public init(config: AppConfig, token: String) {
        self.config = config; self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        client = HTTPClient(session: URLSession(configuration: configuration))
    }
    public func comments() async throws -> [ClientPersonalComment] {
        let response: CommentsResponse = try await request("api/v2/client-personal-comments")
        guard Set(response.comments.map(\.id)).count == response.comments.count else { throw AppServiceError.message("Сервер вернул повторяющиеся комментарии.") }
        return response.comments
    }
    public func save(_ draft: ClientPersonalCommentDraft) async throws -> ClientPersonalComment {
        var body: [String: Any] = ["displayTIN": draft.tin, "targets": draft.targets.map { ["address": $0.address] },
                                  "terminalIDs": draft.terminalIDs, "contactPerson": draft.contactPerson,
                                  "phone": draft.normalizedPhone, "email": draft.email, "extraInfo": draft.extraInfo]
        if let id = draft.serverID { body["id"] = id }
        if let source = draft.sourceCommentID { body["sourceCommentID"] = source }
        let response: CommentResponse = try await request("api/v2/client-personal-comments", method: "POST", body: body)
        guard !response.comment.id.isEmpty, response.comment.normalizedTIN == draft.normalizedTIN,
              draft.serverID == nil || draft.serverID == response.comment.id else { throw AppServiceError.message("Сервер вернул некорректный комментарий. Обновите данные перед повтором.") }
        return response.comment
    }
    public func company(_ tin: String) async throws -> CompanyLookupCompany {
        let response: CompanyResponse = try await request("api/v2/reference/companies/" + tin)
        guard response.company.inn == tin else { throw AppServiceError.message("Сервер вернул данные другой организации.") }
        return response.company
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Any? = nil) async throws -> T {
        let base = try AppConfig.validatedURL(config.lumaWorkAPIOrigin)
        let response = try await client.request(base.appendingPathComponent(path), method: method, body: body,
                                               authToken: token, headers: ["X-LumaWork-Personal-Comments-Version": "2"], redactDiagnostics: true)
        guard let json = response.json else { throw AppServiceError.message("Сервер вернул пустой ответ.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = ClientPersonalCommentDateCoding.strategy
        do { return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: json)) }
        catch { throw AppServiceError.message("Сервер вернул некорректные данные.") }
    }
    private struct CommentsResponse: Decodable { let comments: [ClientPersonalComment] }
    private struct CommentResponse: Decodable { let comment: ClientPersonalComment }
    private struct CompanyResponse: Decodable { let company: CompanyLookupCompany }
}
