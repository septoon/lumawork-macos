import Foundation

public struct SimpleOneEmployeeAddress: Codable, Hashable, Identifiable, Sendable {
    public var sysID: String
    public var title: String
    public var region: String
    public var federalRegion: String

    public var id: String { sysID }

    public var subtitle: String {
        [region, federalRegion]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != title }
            .joined(separator: " · ")
    }
}

public struct SimpleOneEmployeeField: Codable, Hashable, Identifiable, Sendable {
    public var systemName: String
    public var title: String
    public var value: String

    public var id: String { systemName + "|" + title }
}

public struct SimpleOneEmployeeSection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var fields: [SimpleOneEmployeeField]
}

public struct SimpleOneEmployee: Codable, Hashable, Identifiable, Sendable {
    public var sysID: String
    public var displayName: String
    public var firstName: String
    public var lastName: String
    public var middleName: String
    public var login: String
    public var email: String
    public var position: String
    public var manager: String
    public var company: String
    public var department: String
    public var phone: String
    public var address: SimpleOneEmployeeAddress?
    public var isActive: Bool?
    public var isLocked: Bool?
    public var updatedAt: String
    public var detailSections: [SimpleOneEmployeeSection]

    public var id: String { sysID }

    public var fullName: String {
        let assembled = [lastName, firstName, middleName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return assembled.isEmpty ? displayName : assembled
    }

    public var sortName: String {
        [fullName, displayName, login]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    public var initials: String {
        let preferred = [firstName, lastName]
            .compactMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).first
            }
        let fallback = fullName
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap(\.first)
        return String((preferred.isEmpty ? fallback : preferred).prefix(2)).uppercased()
    }

    public var roleText: String {
        [position, department]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Должность не указана"
    }
}
