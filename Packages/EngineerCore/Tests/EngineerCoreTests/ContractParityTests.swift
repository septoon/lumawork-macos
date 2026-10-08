import XCTest
@testable import EngineerCore

// Session-local handlers: tests never register a global protocol or contact the network.
final class FixtureURLProtocol: URLProtocol {
    struct Reply { var status: Int; var data: Data }
    static let lock = NSLock()
    static var handlers: [String: (URLRequest) throws -> Reply] = [:]

    static func install(_ handler: @escaping (URLRequest) throws -> Reply) -> URLSession {
        let key = UUID().uuidString
        lock.lock()
        handlers[key] = handler
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-Key": key]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = request.value(forHTTPHeaderField: "X-Fixture-Key").flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        do {
            let reply = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func bodyData(of request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class ContractParityTests: XCTestCase {
    func testRequestShape() async throws {
        let session = FixtureURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.invalid/api/v2/records?from=2026-10-08")
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-LumaWork-Version"), AppBuildIdentity.version)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-LumaWork-Build"), AppBuildIdentity.build)
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            let body = try FixtureURLProtocol.bodyData(of: request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["workType"] as? String, "ARM")
            XCTAssertEqual(json["distanceKm"] as? Double, 123.5)
            XCTAssertTrue(json["coordinateOverride"] is NSNull)
            return .init(status: 204, data: Data())
        }
        defer { session.invalidateAndCancel() }
        _ = try await HTTPClient(session: session).request(URL(string: "https://api.example.invalid/api/v2/records?from=2026-10-08")!, method: "PUT", body: ["workType": "ARM", "distanceKm": 123.5, "coordinateOverride": NSNull()], authToken: "fixture-token")
    }

    func testResponseShape() async throws {
        let data = try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "http-records", withExtension: "json", subdirectory: "Fixtures")))
        let session = FixtureURLProtocol.install { _ in .init(status: 200, data: data) }
        defer { session.invalidateAndCancel() }
        let response = try await HTTPClient(session: session).request(URL(string: "https://api.example.invalid/records")!)
        XCTAssertEqual(response.statusCode, 200)
        let records = try XCTUnwrap((response.json as? [String: Any])?["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?["id"] as? String, "fixture-record-001")
        XCTAssertTrue(records.first?["optional"] is NSNull)
        XCTAssertEqual(records.first?["extraServerField"] as? String, "ignored")
    }

    func testEmptyAnd204KeepNilJSON() async throws {
        for status in [200, 204] {
            let session = FixtureURLProtocol.install { request in
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
                return .init(status: status, data: Data())
            }
            defer { session.invalidateAndCancel() }
            let response = try await HTTPClient(session: session).request(URL(string: "https://api.example.invalid/empty")!, authToken: "")
            XCTAssertEqual(response.statusCode, status)
            XCTAssertNil(response.json)
        }
    }

    func testHTTPFailuresPreserveStatus() async throws {
        for status in [401, 403, 404, 429, 500, 502] {
            let session = FixtureURLProtocol.install { _ in .init(status: status, data: Data("{}".utf8)) }
            defer { session.invalidateAndCancel() }
            do {
                _ = try await HTTPClient(session: session).request(URL(string: "https://api.example.invalid/error")!)
                XCTFail("HTTP \(status) must fail")
            } catch AppServiceError.http(let actual, let fallback) {
                XCTAssertEqual(actual, status)
                XCTAssertEqual(fallback, "Ошибка сервера")
            }
        }
    }

    func testMalformedResponseIsNotSuccessful() async throws {
        let session = FixtureURLProtocol.install { _ in .init(status: 200, data: Data("not-json".utf8)) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await HTTPClient(session: session).request(URL(string: "https://api.example.invalid/broken")!)
            XCTFail("Invalid JSON must fail")
        } catch { XCTAssertFalse(error is AppServiceError) }
    }

    func testInvalidOriginDoesNotStartARequest() async throws {
        let session = FixtureURLProtocol.install { _ in
            XCTFail("Invalid origin reached transport")
            return .init(status: 200, data: Data())
        }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await HTTPClient(session: session).request(try AppConfig.validatedURL("$(API_URL)"))
            XCTFail("Invalid origin must fail explicitly")
        } catch AppServiceError.message(let message) {
            XCTAssertEqual(message, "Не настроен адрес сервера.")
        }
    }
}
