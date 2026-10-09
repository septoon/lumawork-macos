import Foundation

public struct Vehicle: Codable, Identifiable, Hashable, Sendable {
    public struct GsmSettings: Codable, Hashable, Sendable {
        public var fuelNorm: Double
        public var fuelType: String
        public var defaultStartOdometer: Int
        public var reportStartMonth: String
    }

    public var id: String
    public var make: String?
    public var model: String?
    public var generation: String?
    public var year: Int?
    public var bodyType: String?
    public var colorName: String?
    public var customName: String?
    public var licensePlate: String?
    public var vin: String?
    public var sts: String?
    public var pts: String?
    public var engineVolumeCm3: Int?
    public var enginePowerHp: Int?
    public var currentMileageKm: Int?
    public var isPrimary: Bool
    public var imageURL: URL?
    public var imageStatus: String
    public var gsmSettings: GsmSettings?
    public var documents: [VehicleDocument]?

    public var displayName: String {
        UserProfileData.clean(customName)
            ?? [make, model].compactMap(UserProfileData.clean).joined(separator: " ").nilIfBlank
            ?? "Автомобиль"
    }

    public var modelLine: String {
        [make, model, generation].compactMap(UserProfileData.clean).joined(separator: " ")
    }

    public func fillingMissingFields(from profile: UserProfileData) -> Vehicle {
        merging(profile: profile, overwritingExisting: false)
    }

    public func merging(profile: UserProfileData, overwritingExisting: Bool) -> Vehicle {
        var result = self

        func mergedText(_ current: String?, _ legacy: String?) -> String? {
            guard let legacy = UserProfileData.clean(legacy) else { return current }
            return overwritingExisting || UserProfileData.clean(current) == nil ? legacy : current
        }

        func parsedNumber(_ value: String?) -> Int? {
            guard let value = UserProfileData.clean(value) else { return nil }
            let digits = value.filter(\.isNumber)
            return digits.isEmpty ? nil : Int(digits)
        }

        func mergedNumber(_ current: Int?, _ legacy: String?) -> Int? {
            guard let legacy = parsedNumber(legacy) else { return current }
            return overwritingExisting || current == nil ? legacy : current
        }

        result.customName = mergedText(customName, profile.vehicleModel)
        result.licensePlate = mergedText(licensePlate, profile.vehiclePlate)
        result.vin = mergedText(vin, profile.vehicleVin)
        result.sts = mergedText(sts, profile.vehicleSts)
        result.pts = mergedText(pts, profile.vehiclePts)
        result.colorName = mergedText(colorName, profile.vehicleColor)
        result.engineVolumeCm3 = mergedNumber(engineVolumeCm3, profile.engineVolumeCm3)
        result.enginePowerHp = mergedNumber(enginePowerHp, profile.enginePowerHp)
        result.currentMileageKm = mergedNumber(currentMileageKm, profile.initialMileageKm)
        return result
    }
}

public struct VehicleDraft: Hashable, Sendable {
    public var licensePlate = ""
    public var vin = ""
    public var sts = ""
    public var pts = ""
    public var make = ""
    public var model = ""
    public var generation = ""
    public var year = ""
    public var bodyType = ""
    public var colorName = ""
    public var currentMileageKm = ""
    public var engineVolumeCm3 = ""
    public var enginePowerHp = ""
    public var customName = ""
    public var isPrimary = false

    public init() {}

    public init(vehicle: Vehicle) {
        licensePlate = vehicle.licensePlate ?? ""
        vin = vehicle.vin ?? ""
        sts = vehicle.sts ?? ""
        pts = vehicle.pts ?? ""
        make = vehicle.make ?? ""
        model = vehicle.model ?? ""
        generation = vehicle.generation ?? ""
        year = vehicle.year.map(String.init) ?? ""
        bodyType = vehicle.bodyType ?? ""
        colorName = vehicle.colorName ?? ""
        currentMileageKm = vehicle.currentMileageKm.map(String.init) ?? ""
        engineVolumeCm3 = vehicle.engineVolumeCm3.map(String.init) ?? ""
        enginePowerHp = vehicle.enginePowerHp.map(String.init) ?? ""
        customName = vehicle.customName ?? ""
        isPrimary = vehicle.isPrimary
    }

    public init(profile: UserProfileData) {
        licensePlate = UserProfileData.clean(profile.vehiclePlate) ?? ""
        vin = UserProfileData.clean(profile.vehicleVin) ?? ""
        sts = UserProfileData.clean(profile.vehicleSts) ?? ""
        pts = UserProfileData.clean(profile.vehiclePts) ?? ""
        model = UserProfileData.clean(profile.vehicleModel) ?? ""
        colorName = UserProfileData.clean(profile.vehicleColor) ?? ""
        currentMileageKm = Self.numberString(profile.initialMileageKm)
        engineVolumeCm3 = Self.numberString(profile.engineVolumeCm3)
        enginePowerHp = Self.numberString(profile.enginePowerHp)
        customName = UserProfileData.clean(profile.vehicleModel) ?? ""
        isPrimary = true
    }

    public var hasVehicleData: Bool {
        [
            licensePlate, vin, sts, pts, make, model, generation, year, bodyType,
            colorName, currentMileageKm, engineVolumeCm3, enginePowerHp, customName
        ].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func numberString(_ value: String?) -> String {
        guard let value = UserProfileData.clean(value) else { return "" }
        return String(value.filter(\.isNumber))
    }

    public func payload() throws -> [String: Any] {
        guard hasVehicleData else { throw AppServiceError.message("Заполните сведения об автомобиле.") }
        if let error = VehicleInputValidation.plateError(licensePlate) { throw AppServiceError.message(error) }
        if let error = VehicleInputValidation.vinError(vin) { throw AppServiceError.message(error) }
        var result: [String: Any] = ["isPrimary": isPrimary]
        let texts = ["licensePlate": licensePlate, "vin": vin, "sts": sts, "pts": pts, "make": make, "model": model,
                     "generation": generation, "bodyType": bodyType, "colorName": colorName, "customName": customName]
        for (key, text) in texts {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count <= (["licensePlate"].contains(key) ? 32 : ["vin", "sts", "pts"].contains(key) ? 64 : 200) else { throw AppServiceError.message("Слишком длинное значение: " + key) }
            result[key] = value.isEmpty ? NSNull() : value as Any
        }
        for (key, text) in [("year", year), ("currentMileageKm", currentMileageKm), ("engineVolumeCm3", engineVolumeCm3), ("enginePowerHp", enginePowerHp)] {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[key] = NSNull(); continue }
            guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else { throw AppServiceError.message("Укажите целое неотрицательное число: " + key) }
            if key == "year", !(1886...(Calendar.current.component(.year, from: Date()) + 1)).contains(value) { throw AppServiceError.message("Некорректный год выпуска.") }
            result[key] = value
        }
        return result
    }
}

public enum VehicleInputValidation {
    private static let latinToCyrillic: [Character: Character] = [
        "A": "А", "B": "В", "E": "Е", "K": "К", "M": "М", "H": "Н",
        "O": "О", "P": "Р", "C": "С", "T": "Т", "Y": "У", "X": "Х"
    ]
    private static let cyrillicToLatin = Dictionary(uniqueKeysWithValues: latinToCyrillic.map { ($0.value, $0.key) })
    private static let plateLetters = CharacterSet(charactersIn: "АВЕКМНОРСТУХ")
    private static let plateDigits = Set("0123456789")
    private static let vinCharacters = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")

    public static func formatPlate(_ value: String) -> String {
        let normalized = value.uppercased().compactMap { character -> Character? in
            if let mapped = latinToCyrillic[character] { return mapped }
            return plateDigits.contains(character) || String(character).rangeOfCharacter(from: plateLetters) != nil ? character : nil
        }
        var masked: [Character] = []
        for character in normalized where masked.count < 9 {
            let expectsLetter = masked.count == 0 || masked.count == 4 || masked.count == 5
            let isLetter = String(character).rangeOfCharacter(from: plateLetters) != nil
            let isDigit = plateDigits.contains(character)
            if (expectsLetter && isLetter) || (!expectsLetter && isDigit) {
                masked.append(character)
            }
        }
        let compact = String(masked)
        guard compact.count > 6 else { return compact }
        return String(compact.prefix(6)) + " " + String(compact.dropFirst(6))
    }

    public static func plateError(_ value: String) -> String? {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return "Введите государственный номер." }
        let pattern = #"^[АВЕКМНОРСТУХ]\d{3}[АВЕКМНОРСТУХ]{2}(\d{2,3})?$"#
        return compact.range(of: pattern, options: .regularExpression) == nil ? "Пример: А123ВС 82 или А123ВС 777." : nil
    }

    public static func normalizedVIN(_ value: String) -> String {
        let normalized = value.uppercased().compactMap { character -> Character? in
            let latin = cyrillicToLatin[character] ?? character
            return vinCharacters.contains(latin) ? latin : nil
        }
        return String(normalized.prefix(24))
    }

    public static func vinError(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        return (value.count < 11 || value.count > 24) ? "VIN обычно содержит 17 символов; допустимо от 11 до 24." : nil
    }
}


private extension String { var nilIfBlank: String? { UserProfileData.clean(self) } }

public enum VehicleDocumentKind: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case osago = "OSAGO"
    case sts = "STS"
    case pts = "PTS"
    case diagnosticCard = "DIAGNOSTIC_CARD"
    case purchaseContract = "PURCHASE_CONTRACT"
    case service = "SERVICE"
    case other = "OTHER"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .osago: "ОСАГО"
        case .sts: "СТС"
        case .pts: "ПТС"
        case .diagnosticCard: "Диагностическая карта"
        case .purchaseContract: "Договор купли-продажи"
        case .service: "Сервисный документ"
        case .other: "Другой документ"
        }
    }

    public var systemImage: String {
        switch self {
        case .osago: "shield"
        case .sts, .pts: "creditcard"
        case .diagnosticCard: "checkmark.seal"
        case .purchaseContract: "signature"
        case .service: "wrench.and.screwdriver"
        case .other: "doc"
        }
    }

    public static func suggested(for fileName: String) -> VehicleDocumentKind {
        let normalized = fileName.lowercased()
        if normalized.contains("осаго") || normalized.contains("osago") || normalized.contains("полис") { return .osago }
        if normalized.contains("стс") || normalized.contains("sts") { return .sts }
        if normalized.contains("птс") || normalized.contains("pts") { return .pts }
        if normalized.contains("диагност") || normalized.contains("то-") { return .diagnosticCard }
        if normalized.contains("дкп") || normalized.contains("договор") { return .purchaseContract }
        if normalized.contains("сервис") || normalized.contains("заказ-наряд") { return .service }
        return .other
    }
}

public struct VehicleDocument: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: VehicleDocumentKind
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int
    public let createdAt: String
}
