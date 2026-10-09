import SwiftUI
import WebKit
import EngineerCore

struct MacSimpleOneBrowser: View {
    let recordID: String?
    let title: String
    let isTimeReport: Bool
    let coordinator: EngineerApplicationCoordinator
    let config: AppConfig
    @Environment(\.dismiss) private var dismiss
    init(record: SimpleOneRequestRecord, coordinator: EngineerApplicationCoordinator, config: AppConfig) {
        recordID = record.sysID; title = record.number; isTimeReport = false
        self.coordinator = coordinator; self.config = config
    }
    init(timeReportRecordID: String?, title: String, coordinator: EngineerApplicationCoordinator, config: AppConfig) {
        recordID = timeReportRecordID; self.title = title; isTimeReport = true
        self.coordinator = coordinator; self.config = config
    }
    private var destination: URL? {
        guard let origin = URL(string: config.simpleOneWebOrigin ?? ""), origin.scheme == "https", origin.host != nil else { return nil }
        if let recordID {
            guard !recordID.isEmpty, recordID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        } else if !isTimeReport { return nil }
        var url = origin.appendingPathComponent(isTimeReport ? "record/itsm_tchnsrv_time_report" : "record/itsm_request")
        if let recordID { url.appendPathComponent(recordID) }
        if isTimeReport { url.append(queryItems: [URLQueryItem(name: "form_view", value: "Внешняя система")]) }
        return url
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("SimpleOne · \(title)").font(.headline); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
            Divider()
            if let credentials = coordinator.simpleOneSession, let context = coordinator.context, let destination {
                MacSimpleOneWebView(url: destination,
                                    authKey: credentials.authKey, context: context, session: coordinator)
                    .id(context.epoch)
            } else { ContentUnavailableView("SimpleOne недоступен", systemImage: "globe", description: Text("Проверьте адрес сервера и вход в SimpleOne.")) }
        }.frame(minWidth: 860, minHeight: 640)
        .onChange(of: coordinator.context) { _, _ in dismiss() }
    }
}

private struct MacSimpleOneWebView: NSViewRepresentable {
    let url: URL
    let authKey: String
    let context: SessionContext
    let session: EngineerApplicationCoordinator
    func makeCoordinator() -> Coordinator { Coordinator(url: url, context: context, session: session) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        guard let host = url.host, let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "auth", .value: authKey, .secure: "TRUE"]) else { return view }
        let gate = context.coordinator
        view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak view] in
            Task { @MainActor in guard gate.isCurrent, let view else { return }; view.load(URLRequest(url: url)) }
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if !context.coordinator.isCurrent { view.stopLoading(); view.loadHTMLString("", baseURL: nil) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.active = false; view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let origin: URL
        let context: SessionContext
        let session: EngineerApplicationCoordinator
        var active = true
        var isCurrent: Bool { active && session.accepts(context) }
        init(url: URL, context: SessionContext, session: EngineerApplicationCoordinator) { origin = url; self.context = context; self.session = session }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard isCurrent, let url = navigationAction.request.url, url.scheme == "https", url.host == origin.host, url.port == origin.port else { decisionHandler(.cancel); return }
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request); decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            guard isCurrent else { completionHandler(); return }
            let alert = NSAlert(); alert.messageText = "SimpleOne"; alert.informativeText = message
            if let window = webView.window { alert.beginSheetModal(for: window) { _ in completionHandler() } }
            else { completionHandler() }
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard isCurrent, let window = webView.window else { completionHandler(false); return }
            let alert = NSAlert(); alert.messageText = "SimpleOne"; alert.informativeText = message; alert.addButton(withTitle: "Продолжить"); alert.addButton(withTitle: "Отмена")
            alert.beginSheetModal(for: window) { [weak self] response in completionHandler(self?.isCurrent == true && response == .alertFirstButtonReturn) }
        }
    }
}
