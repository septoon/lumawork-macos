import Foundation

public struct VirtualCardData: Codable, Hashable, Sendable {
    public var firstName: String
    public var lastName: String
    public var middleName: String
    public var title: String
    public var department: String
    public var phone: String
    public var email: String
    public var organization: String

    public static let `default` = VirtualCardData(
        firstName: "",
        lastName: "",
        middleName: "",
        title: "",
        department: "",
        phone: "",
        email: "",
        organization: ""
    )

    public var fullName: String {
        [lastName, firstName, middleName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var vCard: String {
        let orgLine: String
        if !organization.isEmpty, !department.isEmpty {
            orgLine = "\(organization);\(department)"
        } else {
            orgLine = organization.isEmpty ? department : organization
        }

        return [
            "BEGIN:VCARD",
            "VERSION:3.0",
            "N:\(lastName);\(firstName);\(middleName);;",
            "FN:\(fullName.isEmpty ? "Контакт" : fullName)",
            orgLine.isEmpty ? nil : "ORG:\(orgLine)",
            title.isEmpty ? nil : "TITLE:\(title)",
            phone.isEmpty ? nil : "TEL;TYPE=CELL:\(phone)",
            email.isEmpty ? nil : "EMAIL;TYPE=WORK:\(email)",
            "END:VCARD"
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }
}
