import Foundation

enum ClosedRequestsMerchantTINSupport {
    static func resolvedTIN(directTIN: String, information: String) -> String {
        let directTIN = normalizedValidTIN(directTIN)
        if !directTIN.isEmpty {
            return directTIN
        }

        let normalizedInformation = information
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "&#xA;", with: "\n")
            .replacingOccurrences(
                of: "<br\\s*/?>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        let pattern = #"ИНН\s*ТСП\s*:\s*([0-9][0-9 \t-]{8,20})"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: normalizedInformation,
                range: NSRange(normalizedInformation.startIndex..., in: normalizedInformation)
              ),
              let valueRange = Range(match.range(at: 1), in: normalizedInformation) else {
            return ""
        }

        return normalizedValidTIN(String(normalizedInformation[valueRange]))
    }

    static func normalizedValidTIN(_ raw: String) -> String {
        let digits = raw.filter(\.isNumber)
        return digits.count == 10 || digits.count == 12 ? digits : ""
    }

    static func needsRepair(_ raw: String?) -> Bool {
        normalizedValidTIN(raw ?? "").isEmpty
    }
}
