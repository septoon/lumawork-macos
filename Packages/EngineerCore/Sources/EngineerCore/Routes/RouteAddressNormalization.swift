import Foundation

extension String {
    nonisolated private static let routeCities = ["Алушта", "Ялта", "Севастополь", "Симферополь", "Джанкой"]

    nonisolated func normalizedAddressStartingFromAlushta() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)

        let firstMatchedRange = Self.routeCities
            .compactMap { city in
                trimmed.range(of: city, options: [.caseInsensitive])
            }
            .min { lhs, rhs in
                lhs.lowerBound < rhs.lowerBound
            }

        guard let cityRange = firstMatchedRange else {
            return trimmed
        }

        return String(trimmed[cityRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .normalizedAddressCommaSpacing()
    }

    nonisolated func normalizedAddressCommaSpacing() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: "\\s*,\\s*",
                with: ", ",
                options: .regularExpression
            )
    }

    nonisolated func qualifiedRouteAddress() -> String {
        let address = normalizedAddressCommaSpacing()
        guard !address.isEmpty else { return address }
        let hasExplicitCity = Self.routeCities.contains { address.localizedCaseInsensitiveContains($0) }
        return hasExplicitCity ? address : "Алушта, \(address)"
    }

    nonisolated func qualifiedAppleRouteAddress() -> String {
        // Apple can resolve "ул Набережная, д 9" to the street and discard the house.
        let address = qualifiedRouteAddress()
            .replacingOccurrences(
                of: "(^|[,\\s])ул(?:\\.\\s*|\\s+)",
                with: "$1улица ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "(^|[,\\s])(?:дом|д\\.?)\\s*(?=\\d)",
                with: "$1",
                options: [.regularExpression, .caseInsensitive]
            )
            .normalizedAddressCommaSpacing()

        var parts = address.components(separatedBy: ", ")
        guard parts.count == 3, parts[2].first?.isNumber == true else { return address }
        let streetWords = parts[1].lowercased(with: Locale(identifier: "ru_RU"))
            .split { $0.isWhitespace || $0 == "." }
        let streetTypes = ["улица", "проспект", "пр-т", "пр-кт", "переулок", "пер",
                           "шоссе", "ш", "площадь", "пл", "проезд", "пр-д", "бульвар", "б-р",
                           "тупик", "аллея", "наб"]
        let hasStreetType = streetWords.contains { streetTypes.contains(String($0)) }
            || (streetWords.count > 1 && streetWords.contains("набережная"))
        guard !hasStreetType else { return address }
        parts[1] = "улица \(parts[1])"
        return parts.joined(separator: ", ")
    }

    nonisolated func appleRouteStreetFallbackAddress() -> String? {
        let parts = qualifiedAppleRouteAddress().components(separatedBy: ", ")
        guard parts.count >= 3 else { return nil }
        let building = parts.dropFirst(2).joined(separator: ", ")
        guard !building.contains(where: \.isNumber),
              building.range(of: "\\b(?:б\\s*/\\s*н|без\\s+номера)\\b", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return parts.prefix(2).joined(separator: ", ")
    }
}

// Conservative identity: never merge different towns, house suffixes or building numbers.
extension String {
    nonisolated var routeCoordinateKey: String {
        qualifiedAppleRouteAddress().lowercased(with: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}
