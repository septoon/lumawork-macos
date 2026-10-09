import AppKit
import UniformTypeIdentifiers
import Observation
import EngineerCore

@MainActor @Observable
final class MacSpreadsheetExport {
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var notice: String?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var panel: NSSavePanel?
    @ObservationIgnored private var preparation: Task<Data, Error>?

    func reset() {
        operation = nil; preparation?.cancel(); preparation = nil
        panel?.cancel(nil); panel = nil
        isBusy = false; error = nil; notice = nil
    }
    func save(name: String, coordinator: EngineerApplicationCoordinator,
              makeData: @escaping @Sendable () throws -> Data) {
        guard !isBusy, let context = coordinator.context, let window = NSApp.keyWindow else { return }
        let id = UUID()
        operation = id; isBusy = true; error = nil; notice = nil
        Task { await perform(name: name, coordinator: coordinator, context: context, window: window, id: id, makeData: makeData) }
    }
    private func perform(name: String, coordinator: EngineerApplicationCoordinator, context: SessionContext,
                         window: NSWindow, id: UUID, makeData: @escaping @Sendable () throws -> Data) async {
        defer { if operation == id { operation = nil; preparation = nil; panel = nil; isBusy = false } }
        guard operation == id, coordinator.accepts(context), window.isVisible else { return }
        do {
            let task = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try makeData() }
            preparation = task
            let data = try await task.value
            guard operation == id, coordinator.accepts(context), window.isVisible, !Task.isCancelled else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            self.panel = panel
            let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            guard response == .OK, operation == id, coordinator.accepts(context), window.isVisible, !Task.isCancelled, let url = panel.url else { return }
            // Final session check and write run together on the main actor after the user confirms.
            try data.write(to: url, options: .atomic)
            notice = "XLSX сохранён."
        } catch {
            guard operation == id, coordinator.accepts(context), !AppErrorClassification.isCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }
}
