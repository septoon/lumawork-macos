import Foundation

public enum WorkDocumentCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case employmentContract = "EMPLOYMENT_CONTRACT", certificate = "CERTIFICATE", regulation = "REGULATION", instruction = "INSTRUCTION", application = "APPLICATION", qualification = "QUALIFICATION", other = "OTHER"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .employmentContract: "Трудовые договоры"
        case .certificate: "Справки"
        case .regulation: "Положения"
        case .instruction: "Инструкции"
        case .application: "Заявления"
        case .qualification: "Удостоверения и обучение"
        case .other: "Прочее"
        }
    }
    public static func suggested(_ name: String) -> Self {
        let value = name.lowercased()
        if value.contains("труд") || value.contains("договор") { return .employmentContract }
        if value.contains("справ") || value.contains("мед") { return .certificate }
        if value.contains("положен") || value.contains("регламент") { return .regulation }
        if value.contains("инструк") { return .instruction }
        if value.contains("заявлен") { return .application }
        if value.contains("удостовер") || value.contains("обуч") || value.contains("сертифик") { return .qualification }
        return .other
    }
}
public enum DocumentCollection: Hashable, Codable, Sendable {
    case work, vehicle(String), salary
    public var isProtected: Bool { self == .salary }
    public var title: String { switch self { case .work: "Рабочие документы"; case .vehicle: "Документы автомобиля"; case .salary: "Расчётные листки" } }
    var cacheKey: String { switch self { case .work: "work"; case .vehicle(let id): "vehicle." + id; case .salary: "salary" } }
    var path: String {
        get throws {
            switch self {
            case .work: return "/api/v2/work-documents"
            case .vehicle(let id): return "/api/v2/vehicles/" + (try DomainHTTPClient.id(id)) + "/documents"
            case .salary: return "/api/v2/salary/documents"
            }
        }
    }
    public var allowedMIMETypes: Set<String> {
        let images: Set<String> = ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/heif", "image/webp"]
        switch self {
        case .salary: return ["application/pdf", "text/html"]
        case .vehicle: return images
        case .work: return images.union(["application/msword", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "application/vnd.ms-excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "application/vnd.ms-powerpoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/rtf", "text/rtf", "text/plain"])
        }
    }
}
// Optional fields reflect three existing wire envelopes, not three competing caches.
public struct ServerDocument: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let fileName: String
    public let mimeType: String
    public let sizeBytes: Int
    public let createdAt: String
    public let updatedAt: String?
    public let category: WorkDocumentCategory?
    public let title: String?
    public let kind: VehicleDocumentKind?
    public let month: String?
    public var displayName: String { title ?? fileName }
    public var groupTitle: String { category?.title ?? kind?.title ?? month.map(GsmFuelFormatting.monthLabel) ?? "" }
    public static let maximumBytes = 20 * 1024 * 1024
    public static func validMonth(_ value: String) -> Bool { value.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil }
}
public struct DocumentUpload: Sendable {
    public let id: String
    public let fileName: String
    public let mimeType: String
    public let data: Data
    public var category: WorkDocumentCategory
    public var kind: VehicleDocumentKind
    public var title: String
    public var month: String
    public init(fileName: String, mimeType: String, data: Data) {
        id = UUID().uuidString; self.fileName = fileName; self.mimeType = mimeType; self.data = data
        category = .suggested(fileName); kind = .suggested(for: fileName)
        title = (fileName as NSString).deletingPathExtension; let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM"; month = formatter.string(from: Date())
    }
    public func validate(for collection: DocumentCollection) throws {
        guard !data.isEmpty, data.count <= ServerDocument.maximumBytes else { throw AppServiceError.message("Выберите непустой документ до 20 МБ.") }
        guard collection.allowedMIMETypes.contains(mimeType) else { throw AppServiceError.message("Этот формат документа не поддерживается.") }
        guard !fileName.isEmpty, fileName.count <= 240 else { throw AppServiceError.message("Имя файла должно содержать до 240 символов.") }
        if collection == .work { guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200 else { throw AppServiceError.message("Название должно содержать от 1 до 200 символов.") } }
        if collection == .salary { guard ServerDocument.validMonth(month) else { throw AppServiceError.message("Укажите месяц в формате YYYY-MM.") } }
    }
}
