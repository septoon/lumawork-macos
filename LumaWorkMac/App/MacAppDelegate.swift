import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MacDraftRegistry.shared.hasDirtyDrafts else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await MacDraftRegistry.shared.confirm()) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
