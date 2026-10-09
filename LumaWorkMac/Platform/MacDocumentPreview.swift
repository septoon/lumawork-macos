import SwiftUI
import Quartz
import WebKit

struct MacDocumentPreview: View {
    let url: URL
    let title: String
    let mimeType: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline).lineLimit(1); Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(12)
            Divider()
            if mimeType == "text/html" { MacHTMLDocumentPreview(url: url) }
            else if mimeType.hasPrefix("image/") { MacImageDocumentPreview(url: url) }
            else { MacQuickLookPreview(url: url) }
        }.frame(minWidth: 650, idealWidth: 850, minHeight: 500, idealHeight: 700)
    }
}
private struct MacQuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { let view = QLPreviewView(frame: .zero, style: .normal)!; view.autostarts = true; return view }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}
private struct MacHTMLDocumentPreview: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration); view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }; context.coordinator.loaded = url
        // Multiple CSP policies intersect; an embedded policy cannot re-enable network or scripting.
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; frame-src 'none'; form-action 'none'\">"
        view.loadHTMLString(policy + ((try? String(contentsOf: url, encoding: .utf8)) ?? "Документ недоступен."), baseURL: nil)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil; view.loadHTMLString("", baseURL: nil) }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel) }
    }
}

private struct MacImageDocumentPreview: View {
    let url: URL
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(16) }
            else { ContentUnavailableView("Не удалось открыть изображение", systemImage: "photo") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            let result = await Task.detached(priority: .userInitiated) { MacImageAdapter.thumbnail(file: url, maximumPixelSize: 1600) }.value
            guard !Task.isCancelled else { return }; image = result
        }
        .onDisappear { image = nil; MacImageAdapter.remove(file: url) }
    }
}
