import AppKit
import SwiftUI

// NSTextView supplies Return/Shift-Return, IME composition and native image paste.
struct MacAssistantComposer: NSViewRepresentable {
    @Binding var text: String
    let enabled: Bool
    let submit: () -> Void
    let pasteImage: (Data) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let view = InputView(); view.delegate = context.coordinator; view.isRichText = false; view.allowsUndo = true; view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.textContainerInset = NSSize(width: 6, height: 8); view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true; view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.setAccessibilityLabel("Вопрос помощнику"); view.pasteImage = pasteImage; view.string = text; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.owner = self
        guard let view = scroll.documentView as? InputView else { return }
        view.isEditable = enabled; view.pasteImage = pasteImage
        if !view.hasMarkedText(), view.string != text { view.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: MacAssistantComposer
        init(_ owner: MacAssistantComposer) { self.owner = owner }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView { owner.text = view.string } }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSTextView.insertNewline(_:)), !textView.hasMarkedText(), NSEvent.modifierFlags.intersection([.shift, .option, .control]).isEmpty else { return false }
            if owner.enabled { owner.submit() }; return true
        }
    }
    final class InputView: NSTextView {
        var pasteImage: ((Data) -> Void)?
        override func paste(_ sender: Any?) {
            guard isEditable else { return }
            if let data = NSPasteboard.general.data(forType: .png) { pasteImage?(data); return }
            if let image = NSImage(pasteboard: .general), let data = image.tiffRepresentation { pasteImage?(data); return }
            super.paste(sender)
        }
    }
}
