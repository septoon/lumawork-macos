import Foundation

public enum RouteMapAddressValidation {
    private static let ignored: Set<String> = ["улица", "ул", "д", "дом", "г", "город", "проспект", "пр", "т", "переулок", "пер", "шоссе", "ш", "площадь", "пл", "проезд", "бульвар", "б", "р", "набережная"]
    private static let kinds = ["улица": "улица", "ул": "улица", "проспект": "проспект", "переулок": "переулок", "пер": "переулок", "шоссе": "шоссе", "ш": "шоссе", "площадь": "площадь", "пл": "площадь", "проезд": "проезд", "бульвар": "бульвар", "набережная": "набережная"]

    public static func matches(query: String, found: String) -> Bool {
        let parts = query.qualifiedAppleRouteAddress().components(separatedBy: ", ")
        guard parts.count >= 3, parts.last?.first?.isNumber == true,
              matchesStreet(query: query, found: found) else { return false }
        // Consume town/street tokens first: the '9' in '9 Мая' is not evidence of house 9.
        var actual = tokens(found).filter { !ignored.contains($0) || $0 == "набережная" }
        let location = tokens(parts[0]).filter { !ignored.contains($0) }
            + tokens(parts[1]).filter { !ignored.contains($0) || $0 == "набережная" }
        guard consume(location, from: &actual) else { return false }
        let house = tokens(parts.dropFirst(2).joined(separator: ", ")).filter { !ignored.contains($0) }
        return !house.isEmpty && consume(house, from: &actual)
    }
    public static func matchesStreet(query: String, found: String) -> Bool {
        let parts = query.qualifiedAppleRouteAddress().components(separatedBy: ", ")
        guard parts.count >= 2 else { return false }
        // A missing or different street type is ambiguous; retain the candidate as unverified.
        if let required = kind(parts[1]), kind(found) != required { return false }
        var actual = tokens(found)
        let city = tokens(parts[0]).filter { !ignored.contains($0) }
        let street = tokens(parts[1]).filter { !ignored.contains($0) || $0 == "набережная" }
        return !city.isEmpty && !street.isEmpty && consume(city + street, from: &actual)
    }
    private static func consume(_ expected: [String], from actual: inout [String]) -> Bool {
        for token in expected {
            guard let index = actual.firstIndex(of: token) else { return false }
            actual.remove(at: index)
        }
        return true
    }
    private static func kind(_ value: String) -> String? {
        let words = tokens(value)
        guard words.count > 1 else { return nil }
        return words.compactMap { kinds[$0] }.first
    }
    private static func tokens(_ value: String) -> [String] {
        value.lowercased(with: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "\\bпр[-.\\s]*(?:т|кт)\\b", with: "проспект", options: .regularExpression)
            .replacingOccurrences(of: "(\\d)[-\\s]+([а-яa-z])(?=$|[,\\s])", with: "$1$2", options: .regularExpression)
            .split { !$0.isLetter && !$0.isNumber && $0 != "/" }.map(String.init)
    }
}
