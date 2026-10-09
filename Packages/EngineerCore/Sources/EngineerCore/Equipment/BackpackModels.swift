import Foundation

public struct BackpackItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var serialNumber: String
    public var responsible: String
    public var receivedAt: String
    public var receivedAtDate: Date?
    public var quantity: Int
}

public enum BackpackItemLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case warehouse
    case car
    case home
    case absent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .warehouse: "На складе"
        case .car: "В машине"
        case .home: "Дома"
        case .absent: "Отсутствует"
        }
    }

    public var systemImage: String {
        switch self {
        case .warehouse: "shippingbox.fill"
        case .car: "car.fill"
        case .home: "house.fill"
        case .absent: "questionmark.circle.fill"
        }
    }

    public static func storageIdentity(for item: BackpackItem) -> String {
        let serialNumber = item.serialNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return serialNumber.isEmpty || serialNumber == "(не задано)"
            ? item.id
            : serialNumber
    }

    public static func legacyStorageKey(for item: BackpackItem) -> String {
        "backpack-terminal-location-v1.\(storageIdentity(for: item))"
    }
}
