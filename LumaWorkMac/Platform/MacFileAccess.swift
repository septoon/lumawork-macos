import AppKit
import UniformTypeIdentifiers
import Observation
import EngineerCore

@MainActor @Observable
final class MacFileAccess {
    private var panel: NSSavePanel?
    private var operation: UUID?
    private var readTask: Task<Data, Error>?
    private var copyTask: Task<Void, Error>?
    func reset() { operation = nil; panel?.cancel(nil); panel = nil; readTask?.cancel(); readTask = nil; copyTask?.cancel(); copyTask = nil }
    func choose(collection: DocumentCollection, window: NSWindow, valid: @escaping () -> Bool) async throws -> DocumentUpload? {
        guard valid(), window.isVisible else { throw CancellationError() }
        let id = UUID(); operation = id
        let picker = NSOpenPanel(); panel = picker
        picker.allowsMultipleSelection = false; picker.canChooseDirectories = false
        picker.allowedContentTypes = collection.allowedMIMETypes.compactMap { UTType(mimeType: $0) }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in picker.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        guard operation == id, valid(), window.isVisible else { throw CancellationError() }
        defer { if operation == id { panel = nil; readTask = nil; operation = nil } }
        guard response == .OK, let url = picker.url else { return nil }
        let mime = Self.mimeType(url)
        guard collection.allowedMIMETypes.contains(mime) else { throw AppServiceError.message("Этот формат документа не поддерживается.") }
        let task = Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard metadata.isRegularFile == true, (metadata.fileSize ?? 0) <= ServerDocument.maximumBytes else { throw AppServiceError.message("Выберите обычный файл до 20 МБ.") }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var data = Data()
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                guard data.count + chunk.count <= ServerDocument.maximumBytes else { throw AppServiceError.message("Документ превышает 20 МБ.") }
                data.append(chunk)
            }
            return data
        }; readTask = task
        let data = try await task.value
        guard operation == id, valid(), window.isVisible else { throw CancellationError() }
        return DocumentUpload(fileName: url.lastPathComponent, mimeType: mime, data: data)
    }
    func save(file: URL, name: String, bookmark: Data? = nil, window: NSWindow, valid: @escaping () -> Bool) async throws -> Bool {
        guard valid(), window.isVisible else { throw CancellationError() }
        let id = UUID(); operation = id
        let picker = NSSavePanel(); panel = picker; picker.canCreateDirectories = true
        var rememberedFolder: URL?
        if let bookmark {
            var stale = false
            let folder = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale, folder.startAccessingSecurityScopedResource() else { throw AppServiceError.message("Папка сохранения недоступна. Выберите её заново.") }
            rememberedFolder = folder; picker.directoryURL = folder
        }
        defer { rememberedFolder?.stopAccessingSecurityScopedResource() }
        picker.nameFieldStringValue = (name as NSString).lastPathComponent
        if let type = UTType(filenameExtension: (name as NSString).pathExtension) { picker.allowedContentTypes = [type] }
        defer { if operation == id { panel = nil; operation = nil; copyTask = nil } }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in picker.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        guard operation == id, valid(), window.isVisible else { throw CancellationError() }
        guard response == .OK, let destination = picker.url else { return false }
        let accessed = destination.startAccessingSecurityScopedResource()
        defer { if accessed { destination.stopAccessingSecurityScopedResource() } }
        // Stage beside the selected destination, then replace atomically; never destroy the old file first.
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".engineer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        let copy = Task.detached(priority: .userInitiated) {
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            guard FileManager.default.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: staged); defer { try? output.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        }; copyTask = copy
        try await copy.value
        guard operation == id, valid(), window.isVisible else { throw CancellationError() }
        copyTask = nil
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged) }
        else { try FileManager.default.moveItem(at: staged, to: destination) }
        return true
    }
    func chooseFolder(window: NSWindow, valid: @escaping () -> Bool) async throws -> Data? {
        guard valid(), window.isVisible else { throw CancellationError() }
        let id = UUID(); operation = id
        let picker = NSOpenPanel(); panel = picker
        picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false; picker.canCreateDirectories = true
        picker.prompt = "Выбрать папку"
        defer { if operation == id { panel = nil; operation = nil } }
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in picker.beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        guard operation == id, valid(), window.isVisible else { throw CancellationError() }
        guard response == .OK, let folder = picker.url else { return nil }
        let accessed = folder.startAccessingSecurityScopedResource(); defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        return try folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        case "webp": return "image/webp"
        case "html", "htm": return "text/html"
        case "rtf": return "application/rtf"
        case "txt": return "text/plain"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
