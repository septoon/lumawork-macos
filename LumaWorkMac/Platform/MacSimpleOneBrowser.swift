import SwiftUI
import WebKit
import EngineerCore

struct MacSimpleOneBrowser: View {
    let record: SimpleOneRequestRecord
    let coordinator: EngineerApplicationCoordinator
    let config: AppConfig
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("SimpleOne · \(record.number)").font(.headline); Spacer(); Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
            Divider()
            if let credentials = coordinator.simpleOneSession, let context = coordinator.context,
               let origin = URL(string: config.simpleOneWebOrigin ?? ""), origin.scheme == "https", origin.host != nil,
               !record.sysID.isEmpty, record.sysID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                MacSimpleOneWebView(url: origin.appendingPathComponent("record/itsm_request").appendingPathComponent(record.sysID),
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
