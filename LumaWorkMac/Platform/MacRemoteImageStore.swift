import AppKit
import SwiftUI
import Observation
import CryptoKit
import EngineerCore

@MainActor @Observable
final class MacRemoteImageStore {
    private let context: () -> SessionContext?
    private var bound: SessionContext?
    private var flights: [URL: Task<Void, Never>] = [:]
    private var files: [URL: URL] = [:]
    private var errors: Set<URL> = []
    private var directory: URL?
    private var order: [URL] = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()
    init(context: @escaping () -> SessionContext?) { self.context = context }
    func synchronizeSession() {
        guard bound != context() else { return }
        flights.values.forEach { $0.cancel() }; flights = [:]; files = [:]; errors = []; order = []
        if let directory { MacImageAdapter.remove(file: directory); try? FileManager.default.removeItem(at: directory) }
        directory = nil; bound = context()
    }
    func file(_ url: URL) -> URL? { bound == context() ? files[url] : nil }
    func failed(_ url: URL) -> Bool { bound == context() && errors.contains(url) }
    func load(_ url: URL, force: Bool = false) async {
        synchronizeSession()
        guard let captured = bound, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return }
        if let task = flights[url] { await task.value; return }
        if files[url] != nil, !force { return }
        let root: URL
        if let directory { root = directory } else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineerMac-RemoteImages", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            directory = root
        }
        let task = Task {
            do {
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                let (temp, response) = try await self.session.download(for: request)
                defer { try? FileManager.default.removeItem(at: temp) }
                try Task.checkCancellation()
                guard self.context() == captured, self.bound == captured else { return }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      ((try temp.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max) <= 10 * 1024 * 1024,
                      MacImageAdapter.thumbnail(file: temp) != nil else { throw GsmFuelError.invalidResponse }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
                let file = root.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: temp, to: file)
                self.files[url] = file; self.errors.remove(url); self.order.removeAll { $0 == url }; self.order.append(url)
                while self.order.count > 80 {
                    let expired = self.order.removeFirst()
                    if let old = self.files.removeValue(forKey: expired) { try? FileManager.default.removeItem(at: old) }
                }
            } catch {
                if self.bound == captured, !AppErrorClassification.isCancellation(error) { self.errors.insert(url) }
            }
        }
        flights[url] = task; await task.value
        if bound == captured { flights[url] = nil }
    }
}

struct MacRemotePhoto: View {
    let url: URL?
    let store: MacRemoteImageStore
    var revision = 0
    @State private var showsPreview = false
    var body: some View {
        Group {
            if let url, let file = store.file(url), let image = MacImageAdapter.thumbnail(file: file) {
                Button { showsPreview = true } label: { Image(nsImage: image).resizable().scaledToFit() }
                    .buttonStyle(.plain).help("Увеличить фото")
                    .sheet(isPresented: $showsPreview) {
                        VStack { Image(nsImage: MacImageAdapter.thumbnail(file: file, maximumPixelSize: 1600) ?? image).resizable().scaledToFit(); Button("Закрыть") { showsPreview = false }.keyboardShortcut(.cancelAction) }
                            .padding().frame(width: 620, height: 560)
                    }
            } else if let url {
                VStack(spacing: 8) {
                    if store.failed(url) { Image(systemName: "photo"); Button("Повторить загрузку фото") { Task { await store.load(url, force: true) } } }
                    else { ProgressView().controlSize(.small) }
                }.foregroundStyle(.secondary)
            } else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 180)
        .task(id: "\(url?.absoluteString ?? "")|\(revision)") { if let url { await store.load(url, force: revision > 0) } }
    }
}
