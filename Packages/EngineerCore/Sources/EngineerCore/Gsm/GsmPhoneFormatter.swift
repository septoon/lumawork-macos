import Foundation

public enum GsmPhoneFormatter {
    static let nationalDigitLimit = 10

    public static func format(_ value: String) -> String {
        applyMask(to: nationalDigits(from: value))
    }

    public static func isComplete(_ value: String) -> Bool {
        nationalDigits(from: value).count == nationalDigitLimit
    }

    private static func isDigit(_ character: Character) -> Bool {
        character >= "0" && character <= "9"
    }

    private static func nationalDigits(from value: String) -> String {
        var digits = value.filter(isDigit)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+7"), digits.first == "7" {
            digits.removeFirst()
        } else if digits.count > nationalDigitLimit, digits.first == "7" || digits.first == "8" {
            digits.removeFirst()
        }
        return String(digits.prefix(nationalDigitLimit))
    }

    private static func applyMask(to digits: String) -> String {
        guard !digits.isEmpty else { return "" }
        var result = "+7(" + String(digits.prefix(3))
        if digits.count >= 3 { result += ")" }
        if digits.count > 3 { result += String(digits.dropFirst(3).prefix(3)) }
        if digits.count > 6 { result += "-" + String(digits.dropFirst(6).prefix(2)) }
        if digits.count > 8 { result += "-" + String(digits.dropFirst(8).prefix(2)) }
        return result
    }
}
