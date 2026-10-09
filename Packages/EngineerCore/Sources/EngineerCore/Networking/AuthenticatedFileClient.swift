import Foundation

// Downloads stream to a temporary file. Tokens and server paths are never logged or persisted.
struct AuthenticatedFileClient {
    let config: AppConfig
    let token: String
    func request(path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 120) throws -> URLRequest {
        guard !token.isEmpty else { throw GsmFuelError.unauthorized }
        let origin = try AppConfig.validatedURL(config.lumaWorkAPIOrigin)
        var parts = URLComponents(url: origin.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), resolvingAgainstBaseURL: false)
        if !query.isEmpty { parts?.queryItems = query }
        guard let url = parts?.url else { throw GsmFuelError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream, application/zip, */*", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        AppBuildIdentity.apply(to: &request)
        return request
    }
    func download(path: String, query: [URLQueryItem] = [], maximumBytes: Int64? = nil,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        let request = try request(path: path, query: query, timeout: maximumBytes == nil ? 7 * 24 * 3600 : 120)
        let delegate = FileDownloadDelegate(maximumBytes: maximumBytes, progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let file: URL, response: URLResponse
        do { (file, response) = try await session.download(for: request, delegate: delegate) }
        catch {
            if delegate.sizeLimitExceeded { throw AppServiceError.message("Документ превышает 20 МБ.") }
            throw error
        }
        do {
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw GsmFuelError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                throw AppServiceError.http(status: http.statusCode, fallback: http.statusCode == 404 ? "Файл или папка больше не доступны. Обновите список." : http.statusCode == 502 ? "FTP временно недоступен." : "Не удалось скачать файл")
            }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if let maximumBytes, size > maximumBytes { throw AppServiceError.message("Документ превышает 20 МБ.") }
            // URLSession owns its temporary directory; caller owns only the returned file.
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineerMac-FileDownloads", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let owned = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: file, to: owned)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: owned.path)
            return owned
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
}
private final class FileDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var exceeded = false
    var sizeLimitExceeded: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    let maximumBytes: Int64?
    let progress: @Sendable (Int64, Int64?) -> Void
    init(maximumBytes: Int64?, progress: @escaping @Sendable (Int64, Int64?) -> Void) { self.maximumBytes = maximumBytes; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let maximumBytes, totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { lock.lock(); exceeded = true; lock.unlock(); downloadTask.cancel(); return }
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // File endpoints have no redirects in the contract. Never forward credentials elsewhere.
        completionHandler(nil)
    }
}
