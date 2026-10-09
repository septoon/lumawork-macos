import SwiftUI
import AppKit
import EngineerCore

@MainActor @Observable final class MacAssistantWorkspace {
    var conversationID = UUID()
    var text = ""
    var image: AssistantPreparedImagePayload?
    var document: AssistantPreparedDocumentPayload?
    var attachmentName: String?
    var attachmentPreview: MacDocumentPreviewItem?
    var presentedPreview: MacDocumentPreviewItem?
    let wiki = MacWikiWorkspace()
    var isPreparing = false
    var isEnqueuing = false
    var showsWiki = false
    var historySearch = ""
    var renameID: UUID?
    var renameTitle = ""
    var deleteID: UUID?
    let speech = MacSpeechCapture()
    let fileAccess = MacFileAccess()
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var previewDirectory: URL?
    var hasDirty: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || image != nil || document != nil || isPreparing || speech.isActive }
    func clearAttachment() {
        generation = UUID(); preparation?.cancel(); preparation = nil; fileAccess.reset(); isPreparing = false
        image = nil; document = nil; attachmentName = nil; attachmentPreview = nil; presentedPreview = nil
        if let previewDirectory { MacImageAdapter.remove(file: previewDirectory); try? FileManager.default.removeItem(at: previewDirectory) }; previewDirectory = nil
    }
    func discardComposer() { speech.reset(); text = ""; clearAttachment() }
    func cancelPreparation() { generation = UUID(); preparation?.cancel(); preparation = nil; fileAccess.reset(); isPreparing = false }
    func reset() { wiki.reset(); discardComposer(); conversationID = UUID(); isEnqueuing = false; showsWiki = false; historySearch = ""; renameID = nil; renameTitle = ""; deleteID = nil }
    static let mimeTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/heic", "image/heif", "application/pdf", "text/plain", "text/csv", "application/json", "application/xml", "text/xml", "application/rtf", "text/rtf", "application/msword", "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"]
    func choose(container: MacSessionContainer, url: URL? = nil, pasted: Data? = nil) {
        guard !isPreparing, !isEnqueuing, let captured = container.coordinator.context, let window = NSApp.keyWindow else { return }
        let conversation = conversationID, operation = UUID(); generation = operation; isPreparing = true
        preparation = Task {
            defer { if generation == operation { isPreparing = false; preparation = nil } }
            do {
                let upload: DocumentUpload
                if let url { upload = try await Self.read(url) }
                else if let pasted { guard pasted.count <= 12 * 1024 * 1024 else { throw AssistantDocumentPreparationError.fileTooLarge }; upload = DocumentUpload(fileName: "Изображение.png", mimeType: "image/png", data: pasted) }
                else { guard let value = try await fileAccess.choose(collection: .work, allowedMIMETypes: Self.mimeTypes, maximumBytes: 12 * 1024 * 1024, window: window, valid: { container.coordinator.accepts(captured) && self.generation == operation && self.conversationID == conversation }) else { return }; upload = value }
                try Task.checkCancellation()
                guard container.coordinator.accepts(captured), generation == operation, conversationID == conversation, window.isVisible else { return }
                let preparedImage: AssistantPreparedImagePayload?, preparedDocument: AssistantPreparedDocumentPayload?
                if upload.mimeType.hasPrefix("image/") { preparedImage = try await AssistantImagePreparer.prepare(data: upload.data); preparedDocument = nil }
                else { let value = try await AssistantDocumentPreparer.prepare(data: upload.data, fileName: upload.fileName); preparedImage = value.fallbackImage; preparedDocument = value.payload }
                try Task.checkCancellation()
                guard container.coordinator.accepts(captured), generation == operation, conversationID == conversation, window.isVisible else { return }
                // The original file is local only. Sending uses prepared, bounded payloads.
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("EngineerMac-AssistantPreviews", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let file = root.appendingPathComponent((upload.fileName as NSString).lastPathComponent)
                try upload.data.write(to: file, options: .atomic)
                if let old = previewDirectory { try? FileManager.default.removeItem(at: old) }
                previewDirectory = root; image = preparedImage; document = preparedDocument; attachmentName = upload.fileName
                attachmentPreview = MacDocumentPreviewItem(url: file, title: upload.fileName, mimeType: upload.mimeType)
            } catch { if container.coordinator.accepts(captured), generation == operation, !AppErrorClassification.isCancellation(error) { container.notices.show(error.localizedDescription) } }
        }
    }
    private static func read(_ url: URL) async throws -> DocumentUpload {
        let mime = MacFileAccess.mimeType(url), allowed = mimeTypes
        let task = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard metadata.isRegularFile == true, (metadata.fileSize ?? Int.max) <= 12 * 1024 * 1024 else { throw AssistantDocumentPreparationError.fileTooLarge }
            guard allowed.contains(mime) else { throw AssistantDocumentPreparationError.unsupportedFormat }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var data = Data()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty { try Task.checkCancellation(); guard data.count + chunk.count <= 12 * 1024 * 1024 else { throw AssistantDocumentPreparationError.fileTooLarge }; data.append(chunk) }
            return DocumentUpload(fileName: url.lastPathComponent, mimeType: mime, data: data)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}
