import Foundation

public struct ClientPersonalCommentMatchingIndex: Sendable {
    public struct Entry: Sendable {
        public let id: String
        public let tin: String
        public let addresses: [String]
        public let terminalIDs: [String]
        public init(id: String, tin: String, addresses: [String], terminalIDs: [String]) { self.id = id; self.tin = tin; self.addresses = addresses; self.terminalIDs = terminalIDs }
    }

    private struct TerminalMatch: Sendable {
        let id: String
        let tin: String
    }

    private let byAddress: [String: String]
    private let byTerminalID: [String: TerminalMatch]
    private let globalByTIN: [String: String]

    public init(entries: [Entry]) {
        var addresses: [String: String] = [:]
        var terminals: [String: TerminalMatch] = [:]
        var global: [String: String] = [:]

        for entry in entries {
            let tin = Self.normalizedTIN(entry.tin)
            guard !tin.isEmpty else { continue }
            if entry.addresses.isEmpty, global[tin] == nil {
                global[tin] = entry.id
            }
            for address in entry.addresses {
                let key = Self.normalizedAddress(address)
                if !key.isEmpty, addresses["\(tin)#\(key)"] == nil {
                    addresses["\(tin)#\(key)"] = entry.id
                }
            }
            for terminalID in entry.terminalIDs {
                let key = Self.normalizedTerminalID(terminalID)
                if !key.isEmpty, terminals[key] == nil {
                    terminals[key] = TerminalMatch(id: entry.id, tin: tin)
                }
            }
        }

        byAddress = addresses
        byTerminalID = terminals
        globalByTIN = global
    }

    public func selectedID(tin rawTIN: String, address rawAddress: String, terminalID rawTerminalID: String) -> String? {
        let tin = Self.normalizedTIN(rawTIN)
        let terminalID = Self.normalizedTerminalID(rawTerminalID)
        if !tin.isEmpty {
            let address = Self.normalizedAddress(rawAddress)
            if !address.isEmpty, let match = byAddress["\(tin)#\(address)"] {
                return match
            }
            if let match = byTerminalID[terminalID], match.tin == tin {
                return match.id
            }
            return globalByTIN[tin]
        }
        return byTerminalID[terminalID]?.id
    }

    public static func normalizedTIN(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return digits.count == 10 || digits.count == 12 ? digits : ""
    }

    public static func normalizedAddress(_ raw: String) -> String {
        normalizedScopeText(raw)
    }

    public static func normalizedTerminalID(_ raw: String) -> String {
        normalizedScopeText(raw)
    }

    public static func normalizedScopeText(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .lowercased(with: Locale(identifier: "ru_RU"))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

public enum ClientPersonalCommentPhoneFormatter {
    public static func canonical(_ raw: String) -> String {
        var digits = raw.filter(\.isNumber)
        if digits.count > 10 {
            digits = String(digits.suffix(10))
        } else if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+7")
            || digits.hasPrefix("7")
            || digits.hasPrefix("8") {
            digits.removeFirst()
        }
        return "+7\(digits)"
    }

    public static func display(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        let isRussianNumber = digits.count == 10
            || (digits.count == 11 && (digits.first == "7" || digits.first == "8"))
        guard isRussianNumber else { return trimmed }

        let national = String(digits.suffix(10))
        let area = national.prefix(3)
        let prefix = national.dropFirst(3).prefix(3)
        let firstPair = national.dropFirst(6).prefix(2)
        let secondPair = national.suffix(2)
        return "+7 (\(area)) \(prefix)-\(firstPair)-\(secondPair)"
    }
}

enum ClientPersonalCommentDateCoding {
    static var strategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Неверная дата комментария."
            )
        }
    }
}
