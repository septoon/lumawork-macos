import Foundation

public struct GsmReportResponse: Codable, Hashable, Sendable {
    public let success: Bool
    public let month: String
    public let force: Bool?
    public let skipEmail: Bool?
    public let generated: Bool?
    public let sent: Bool?
    public let status: String?
    public let outputFileName: String?
    public let sentToEmail: String?
    public let durationMs: Int?
    public let output: String?
    public let errorOutput: String?
}

struct GsmOdometerSuggestionResponse: Decodable {
    public let month: String
    public let sourceMonth: String
    public let startOdometer: Int?
}

public struct GsmProjectOption: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let budgetCode: String
}

public struct GsmProfileLoadResult: Codable, Hashable, Sendable {
    public let profile: GsmProfile
    public let availableFuelTypes: [String]
}

public struct GsmProfile: Codable, Hashable, Sendable {
    public var vehicleID: String?
    public var posProjectID: String?
    public var armProjectID: String?
    public var budgetCode: String
    public var employeeFullName: String
    public var employeeShortName: String
    public var employeeReportSignName: String
    public var authorizedFullName: String
    public var authorizedShortName: String
    public var employeeJobTitle: String
    public var employeeCompany: String
    public var employeeAddress: String
    public var employeePhone: String
    public var employeeTitleCompany: String
    public var employeeAddressPhone: String
    public var driverLicenseNumber: String
    public var fuelCardNumber: String
    public var carModel: String
    public var licensePlate: String
    public var fuelNorm: Double
    public var fuelType: String
    public var fuelTypes: [String]
    public var defaultStartOdometer: Int
    public var reportStartMonth: String
    public var projectName: String

    enum CodingKeys: String, CodingKey, CaseIterable {
        case vehicleID = "vehicleId"
        case posProjectID = "posProjectId"
        case armProjectID = "armProjectId"
        case budgetCode, employeeFullName, employeeShortName, employeeReportSignName
        case authorizedFullName, authorizedShortName, employeeJobTitle, employeeCompany
        case employeeAddress, employeePhone, employeeTitleCompany, employeeAddressPhone
        case driverLicenseNumber, fuelCardNumber, carModel, licensePlate, fuelNorm, fuelType, fuelTypes
        case defaultStartOdometer, reportStartMonth, projectName
    }

    public static let empty = GsmProfile(
        vehicleID: nil,
        posProjectID: nil,
        armProjectID: nil,
        budgetCode: "",
        employeeFullName: "",
        employeeShortName: "",
        employeeReportSignName: "",
        authorizedFullName: "",
        authorizedShortName: "",
        employeeJobTitle: "",
        employeeCompany: "",
        employeeAddress: "",
        employeePhone: "",
        employeeTitleCompany: "",
        employeeAddressPhone: "",
        driverLicenseNumber: "",
        fuelCardNumber: "",
        carModel: "",
        licensePlate: "",
        fuelNorm: 0,
        fuelType: "",
        fuelTypes: [],
        defaultStartOdometer: 0,
        reportStartMonth: "2026-04",
        projectName: ""
    )
}

public extension GsmReportResponse {
    var confirmsEmailDelivery: Bool { sent == true || status?.uppercased() == "SENT" }
    var message: String {
        let file = outputFileName ?? "Excel-отчёт"
        if confirmsEmailDelivery { return "\(file) отправлен\(sentToEmail.map { " на " + $0 } ?? "")." }
        return "\(file) сформирован, но отправка письма не подтверждена."
    }
}
