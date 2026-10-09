import Foundation

// Assistant writes and Wiki credentials have no redirect contract.
// Reject redirects rather than forwarding a body, Bearer header or token query.
final class ConfidentialRequestRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Sensitive domain clients share cookie-free, nonredirecting transport.
extension HTTPClient {
    static let confidential: HTTPClient = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        return HTTPClient(session: URLSession(configuration: config, delegate: ConfidentialRequestRedirectBlocker(), delegateQueue: nil))
    }()
}
