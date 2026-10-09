import EngineerCore
@MainActor final class MacBackpackCollector {
    private let original: [BackpackItem]
    private var detailed: [String: BackpackItem] = [:]
    init(_ items: [BackpackItem]) { original = items }
    func receive(_ item: BackpackItem) { detailed[item.id] = item }
    var items: [BackpackItem] { original.map { detailed[$0.id] ?? $0 } }
}
