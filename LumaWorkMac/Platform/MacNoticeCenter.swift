import SwiftUI
import Observation

@MainActor @Observable final class MacNoticeCenter {
    struct Notice: Identifiable { let id = UUID(); let text: String }
    var notice: Notice?
    private var expiry: Task<Void, Never>?
    func show(_ text: String) {
        expiry?.cancel(); let value = Notice(text: text); notice = value
        expiry = Task { try? await Task.sleep(for: .seconds(8)); guard !Task.isCancelled, self.notice?.id == value.id else { return }; self.notice = nil }
    }
    func clear() { expiry?.cancel(); expiry = nil; notice = nil }
}
struct MacNoticeBanner: View {
    let center: MacNoticeCenter
    var body: some View {
        if let notice = center.notice {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.circle")
                Text(notice.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                Spacer(minLength: 10)
                Button { center.clear() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Закрыть уведомление")
            }.font(.callout).padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor))).padding(16).frame(maxWidth: 700).accessibilityElement(children: .contain)
        }
    }
}
