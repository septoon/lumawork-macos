import Foundation

// Assistant writes and Wiki credentials have no redirect contract.
// Reject redirects rather than forwarding a body, Bearer header or token query.
final class ConfidentialRequestRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
