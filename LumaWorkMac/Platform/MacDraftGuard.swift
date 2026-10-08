import AppKit
import SwiftUI

// AppKit is used only for close/terminate interception; the SwiftUI draft remains the source of truth.
@MainActor
final class MacDraftRegistry {
    static let shared = MacDraftRegistry()
    struct Entry {
        weak var window: NSWindow?
        let hasDirty: () -> Bool
        let save: () async throws -> Void
        let discard: () -> Void
    }
    private var entries: [UUID: Entry] = [:]
    private var isPrompting = false
    var hasDirtyDrafts: Bool { entries.values.contains { $0.window != nil && $0.hasDirty() } }
    func register(_ id: UUID, entry: Entry) { entries[id] = entry }
    func unregister(_ id: UUID) { entries[id] = nil }
    func confirm(_ id: UUID? = nil) async -> Bool {
        guard !isPrompting else { return false }
        isPrompting = true; defer { isPrompting = false }
        let candidates = id.map { entries[$0].map { [$0] } ?? [] } ?? Array(entries.values)
        for entry in candidates where entry.window != nil && entry.hasDirty() {
            let alert = NSAlert()
            alert.messageText = "Сохранить изменения маршрута?"
            alert.informativeText = "Черновик будет сохранён только на этом Mac. Для отправки на сервер используйте «Отправить»."
            alert.addButton(withTitle: "Сохранить черновик")
            alert.addButton(withTitle: "Не сохранять")
            alert.addButton(withTitle: "Отмена")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                do { try await entry.save() }
                catch {
                    let failure = NSAlert(); failure.messageText = "Не удалось сохранить черновик"
                    failure.informativeText = error.localizedDescription; failure.addButton(withTitle: "OK"); failure.runModal()
                    return false
                }
            case .alertSecondButtonReturn: entry.discard()
            default: return false
            }
        }
        return true
    }
}

struct MacWindowDraftGuard: NSViewRepresentable {
    let id: UUID
    let hasDirty: () -> Bool
    let save: () async throws -> Void
    let discard: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(id: id) }
    func makeNSView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        context.coordinator.update(self)
        return view
    }
    func updateNSView(_ view: WindowReader, context: Context) { context.coordinator.update(self); context.coordinator.attach(view.window) }
    static func dismantleNSView(_ view: WindowReader, coordinator: Coordinator) { coordinator.detach() }

    final class WindowReader: NSView {
        var attached: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attached?(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let id: UUID
        weak var window: NSWindow?
        weak var original: (any NSWindowDelegate)?
        var callbacks: MacWindowDraftGuard?
        init(id: UUID) { self.id = id }
        func update(_ value: MacWindowDraftGuard) {
            callbacks = value
            if let window { MacDraftRegistry.shared.register(id, entry: .init(window: window, hasDirty: value.hasDirty, save: value.save, discard: value.discard)) }
        }
        func attach(_ newWindow: NSWindow?) {
            guard let newWindow, window !== newWindow else { return }
            detach(); window = newWindow; original = newWindow.delegate; newWindow.delegate = self
            if let callbacks { update(callbacks) }
        }
        func detach() {
            MacDraftRegistry.shared.unregister(id)
            if let window, window.delegate === self { window.delegate = original }
            window = nil; original = nil
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard callbacks?.hasDirty() == true else { return original?.windowShouldClose?(sender) ?? true }
            Task { if await MacDraftRegistry.shared.confirm(id) { sender.performClose(nil) } }
            return false
        }
        func windowWillClose(_ notification: Notification) {
            MacDraftRegistry.shared.unregister(id)
            original?.windowWillClose?(notification)
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }
    }
}
