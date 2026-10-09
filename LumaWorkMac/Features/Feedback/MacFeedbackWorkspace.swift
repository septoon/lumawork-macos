import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import EngineerCore
import Darwin

@MainActor @Observable final class MacFeedbackWorkspace {
    var isPresented = false
    var pending = FeedbackPending()
    var selection: String?
    var search = ""
    var addition = ""
    var isLoadingDraft = false
    var draftLoadError: String?
    var busy = false
    var isPreparing = false
    var preview: MacDocumentPreviewItem?
    private var previewFile: URL?
    private var saved = FeedbackPending()
    private var slot: UUID?
    private var generation = UUID()
    private var persistence: Task<Void, Error>?
    private var preparation: Task<Void, Never>?
    let files = MacFileAccess()
    var hasDirty: Bool { pending.hasContent && pending != saved || !addition.isEmpty || isPreparing }
    func reset() {
        generation = UUID(); persistence?.cancel(); persistence = nil; preparation?.cancel(); preparation = nil; files.reset()
        cleanPreview(); pending = .init(); saved = pending; slot = nil; selection = nil; search = ""; addition = ""; busy = false; isLoadingDraft = false; draftLoadError = nil; isPreparing = false; isPresented = false
    }
    func cleanPreview() {
        if let file = previewFile { MacImageAdapter.remove(file: file); try? FileManager.default.removeItem(at: file) }; previewFile = nil; preview = nil
    }
    func presentPreview(_ item: MacDocumentPreviewItem) { cleanPreview(); previewFile = item.url; preview = item }
    func load(slot: UUID, initialArea: FeedbackArea, container: MacSessionContainer) async {
        guard self.slot != slot, let context = container.coordinator.context else { return }
        if let old = self.slot { container.feedback.release(old) }
        do { try container.feedback.claim(slot) } catch { draftLoadError = error.localizedDescription; return }
        self.slot = slot; let operation = generation; isLoadingDraft = true; draftLoadError = nil
        defer { if generation == operation { isLoadingDraft = false } }
        do {
            try await container.feedback.loadDraftIndex()
            let restored = try await container.feedback.pending(slot: slot)
            guard generation == operation, container.coordinator.accepts(context) else { return }
            if let restored, restored.hasContent { pending = restored; saved = restored }
            else { pending = FeedbackPending(draft: FeedbackDraft(areas: [initialArea])); saved = pending }
        } catch { if generation == operation, container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.feedback.release(slot); self.slot = nil; draftLoadError = error.localizedDescription; container.notices.show(error.localizedDescription) } }
    }
    func release(container: MacSessionContainer) { if let slot { container.feedback.release(slot) }; slot = nil }
    func persist(container: MacSessionContainer) async throws {
        guard let slot, let context = container.coordinator.context, !isLoadingDraft else { return }
        let value = pending, operation = generation, previous = persistence
        let task = Task { if let previous { _ = try? await previous.value }; try Task.checkCancellation(); try await container.feedback.save(value, slot: slot, expectedContext: context) }
        persistence = task; try await task.value
        guard operation == generation, container.coordinator.accepts(context) else { throw CancellationError() }; saved = value
    }
    func send(container: MacSessionContainer) async {
        guard !busy, !isPreparing, !isLoadingDraft, let slot, let context = container.coordinator.context else { return }
        let operation = generation; busy = true; pending.attempted = true; pending.device = pending.device ?? Self.device
        defer { if generation == operation { busy = false } }
        do {
            try await persist(container: container)
            let result = try await container.feedback.submit(pending, slot: slot, device: Self.device, expectedContext: context)
            guard operation == generation, container.coordinator.accepts(context) else { return }
            pending = .init(); saved = pending; selection = result.id
        } catch { if operation == generation, container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } }
    }
    func discardUnsaved(container: MacSessionContainer) async throws {
        let retained = saved
        preparation?.cancel(); files.reset(); isPreparing = false; pending = retained; addition = ""
        try await persist(container: container)
    }
    func discard(container: MacSessionContainer) async throws {
        guard !busy else { return }; pending = .init(); addition = ""; preparation?.cancel(); isPreparing = false; files.reset()
        try await persist(container: container)
    }
    func choose(container: MacSessionContainer, url: URL? = nil) {
        guard !busy, !isPreparing, !pending.attempted, pending.images.count < 4, let context = container.coordinator.context, let window = NSApp.keyWindow else { return }
        let operation = generation; isPreparing = true
        preparation = Task {
            defer { if generation == operation { isPreparing = false; preparation = nil } }
            do {
                let upload: DocumentUpload
                if let url { upload = try await Self.read(url) }
                else {
                    guard let selected = try await files.choose(collection: .work, allowedMIMETypes: ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"], maximumBytes: 20 * 1024 * 1024, window: window, valid: { self.generation == operation && container.coordinator.accepts(context) }) else { return }
                    upload = selected
                }
                let image = try await Task.detached(priority: .userInitiated) { try Self.prepare(upload.data) }.value
                guard generation == operation, container.coordinator.accepts(context), !Task.isCancelled else { return }
                guard pending.images.reduce(image.count, { $0 + $1.data.count }) <= 10 * 1024 * 1024 else { throw AppServiceError.message("Общий размер снимков не должен превышать 10 МБ.") }
                pending.images.append(FeedbackSelectedImage(data: image, fileName: "снимок-\(pending.images.count + 1).jpg"))
                try await persist(container: container)
            } catch { if generation == operation, container.coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } }
        }
    }
    private nonisolated static func read(_ url: URL) async throws -> DocumentUpload {
        try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard info.isRegularFile == true, (info.fileSize ?? 0) <= 20 * 1024 * 1024 else { throw AppServiceError.message("Выберите изображение до 20 МБ.") }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 20 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 20 * 1024 * 1024 else { throw AppServiceError.message("Изображение превышает 20 МБ.") }
            try Task.checkCancellation(); return DocumentUpload(fileName: url.lastPathComponent, mimeType: "image/jpeg", data: data)
        }.value
    }
    private nonisolated static func prepare(_ data: Data) throws -> Data {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2560] as CFDictionary),
              let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AssistantImagePreparationError.invalidImage }
        let rect = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect); context.draw(thumbnail, in: rect)
        guard let image = context.makeImage() else { throw AssistantImagePreparationError.invalidImage }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AssistantImagePreparationError.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 4 * 1024 * 1024 else { throw AssistantImagePreparationError.imageTooLarge }
        return output as Data
    }
    private static var device: FeedbackDeviceInfo {
        var count = 0; sysctlbyname("hw.model", nil, &count, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(1, count)); sysctlbyname("hw.model", &bytes, &count, nil, 0)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return FeedbackDeviceInfo(deviceModel: String(cString: bytes), osVersion: "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", appVersion: AppBuildIdentity.display, language: Locale.current.language.languageCode?.identifier ?? "ru", timeZone: TimeZone.current.identifier, capturedAt: ISO8601DateFormatter().string(from: Date()))
    }
}
