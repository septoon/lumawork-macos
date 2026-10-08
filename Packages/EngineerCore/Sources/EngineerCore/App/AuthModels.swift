import Foundation

public struct AppUser: Codable, Hashable, Sendable {
    public var id: String
    public var email: String
    public var role: String
    public var adminPermissions: [String]?
    public var avatarUrl: String?
    public var profile: UserProfileData?

    public init(id: String, email: String, role: String, adminPermissions: [String]? = nil, avatarUrl: String? = nil, profile: UserProfileData? = nil) {
        self.id = id
        self.email = email
        self.role = role
        self.adminPermissions = adminPermissions
        self.avatarUrl = avatarUrl
        self.profile = profile
    }
}

public enum AdminPermission: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case viewOverview = "overview.view"
    case viewAuditLog = "audit.view"
    case viewGsmTemplate = "gsmTemplate.view"
    case replaceGsmTemplate = "gsmTemplate.replace"
    case viewUsers = "users.view"
    case notifyUsers = "users.notify"
    case blockUsers = "users.block"
    case manageUserPermissions = "users.permissions"
    case deleteUsers = "users.delete"
    case viewImages = "images.view"
    case createImages = "images.create"
    case editImages = "images.edit"
    case deleteImages = "images.delete"
    case viewFeedback = "feedback.view"
    case manageFeedback = "feedback.manage"
    case viewAssistant = "assistant.view"
    case manageAssistant = "assistant.manage"
    case viewSite = "site.view"
    case manageSite = "site.manage"
    case viewEngineerFiles = "engineerFiles.view"
    case manageEngineerFiles = "engineerFiles.manage"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .viewOverview: "Сводка админки"
        case .viewAuditLog: "Журнал действий"
        case .viewGsmTemplate: "Просмотр шаблона ГСМ"
        case .replaceGsmTemplate: "Замена шаблона ГСМ"
        case .viewUsers: "Просмотр пользователей"
        case .notifyUsers: "Рассылка обновлений"
        case .blockUsers: "Блокировка пользователей"
        case .manageUserPermissions: "Роли и права"
        case .deleteUsers: "Удаление пользователей"
        case .viewImages: "Просмотр изображений"
        case .createImages: "Добавление изображений"
        case .editImages: "Замена и переменные"
        case .deleteImages: "Удаление изображений"
        case .viewFeedback: "Просмотр обратной связи"
        case .manageFeedback: "Обработка обратной связи"
        case .viewAssistant: "Статистика ИИ"
        case .manageAssistant: "Настройки и лимиты ИИ"
        case .viewSite: "Просмотр сайта"
        case .manageSite: "Управление сайтом"
        case .viewEngineerFiles: "Просмотр файлов Инженера"
        case .manageEngineerFiles: "Управление файлами Инженера"
        }
    }

    public var detail: String {
        switch self {
        case .viewOverview: "Состояние API, БД и файлового хранилища"
        case .viewAuditLog: "История изменений пользователей и изображений"
        case .viewGsmTemplate: "Просмотр и скачивание шаблона ГСМ-отчёта"
        case .replaceGsmTemplate: "Проверка и установка нового XLTX-шаблона"
        case .viewUsers: "Список и карточки пользователей"
        case .notifyUsers: "Письма об обновлении выбранному пользователю или устаревшим версиям"
        case .blockUsers: "Временная блокировка и разблокировка"
        case .manageUserPermissions: "Назначение администраторов и разрешений"
        case .deleteUsers: "Полное удаление аккаунта и связанных данных"
        case .viewImages: "Единый каталог файлов и привязок"
        case .createImages: "Новые позиции авто и терминалов"
        case .editImages: "Загрузка, замена и редактирование метаданных"
        case .deleteImages: "Удаление файлов с проверкой связей"
        case .viewFeedback: "Сообщения пользователей, снимки и данные устройства"
        case .manageFeedback: "Статусы, приоритеты, заметки и повтор отправки письма"
        case .viewAssistant: "Расходы, токены, модели и статистика пользователей"
        case .manageAssistant: "Системный промпт, словарь и ограничения пользователей"
        case .viewSite: "Состояние, тексты и галерея app.lumastack.ru"
        case .manageSite: "Доступность, тексты, скриншоты и их порядок"
        case .viewEngineerFiles: "Wiki snapshots, IPA-релизы и source.json"
        case .manageEngineerFiles: "Загрузка, замена, переименование, удаление и редактор source.json"
        }
    }

    public var group: AdminPermissionGroup {
        switch self {
        case .viewOverview, .viewAuditLog, .viewGsmTemplate, .replaceGsmTemplate: .overview
        case .viewUsers, .notifyUsers, .blockUsers, .manageUserPermissions, .deleteUsers: .users
        case .viewImages, .createImages, .editImages, .deleteImages: .images
        case .viewFeedback, .manageFeedback: .feedback
        case .viewAssistant, .manageAssistant: .assistant
        case .viewSite, .manageSite: .site
        case .viewEngineerFiles, .manageEngineerFiles: .engineerFiles
        }
    }
}

public enum AdminPermissionGroup: String, CaseIterable, Identifiable {
    case overview
    case users
    case images
    case feedback
    case assistant
    case site
    case engineerFiles

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .overview: "Контроль"
        case .users: "Пользователи"
        case .images: "Изображения"
        case .feedback: "Обратная связь"
        case .assistant: "ИИ-помощник"
        case .site: "Сайт"
        case .engineerFiles: "Файлы Инженера"
        }
    }
}

extension AppUser {
    public var isAdminRole: Bool {
        ["admin", "administrator", "superadmin", "owner"].contains(role.lowercased())
    }

    public var adminPermissionSet: Set<AdminPermission> {
        guard isAdminRole else { return [] }
        guard let adminPermissions else {
            // Backward compatibility for a Keychain session saved before granular permissions existed.
            return Set(AdminPermission.allCases)
        }
        return Set(adminPermissions.compactMap(AdminPermission.init(rawValue:)))
    }

    public func can(_ permission: AdminPermission) -> Bool {
        adminPermissionSet.contains(permission)
    }

    public var canAccessAdminPanel: Bool {
        !adminPermissionSet.isEmpty
    }
}

public struct UserProfileData: Codable, Hashable, Sendable {
    public var firstName: String?
    public var lastName: String?
    public var middleName: String?
    public var jobTitle: String?
    public var departmentTitle: String?
    public var departmentGroup: String?
    public var personnelNumber: String?
    public var city: String?
    public var personalPhone: String?
    public var workEmail: String?
    public var vehicleModel: String?
    public var vehiclePlate: String?
    public var vehicleVin: String?
    public var vehicleSts: String?
    public var vehiclePts: String?
    public var vehicleColor: String?
    public var engineVolumeCm3: String?
    public var enginePowerHp: String?
    public var initialMileageKm: String?
    public var routeWarehouseAddress: String?
    public var routeHomeAddress: String?

    public init(
        firstName: String? = nil,
        lastName: String? = nil,
        middleName: String? = nil,
        jobTitle: String? = nil,
        departmentTitle: String? = nil,
        departmentGroup: String? = nil,
        personnelNumber: String? = nil,
        city: String? = nil,
        personalPhone: String? = nil,
        workEmail: String? = nil,
        vehicleModel: String? = nil,
        vehiclePlate: String? = nil,
        vehicleVin: String? = nil,
        vehicleSts: String? = nil,
        vehiclePts: String? = nil,
        vehicleColor: String? = nil,
        engineVolumeCm3: String? = nil,
        enginePowerHp: String? = nil,
        initialMileageKm: String? = nil,
        routeWarehouseAddress: String? = nil,
        routeHomeAddress: String? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.middleName = middleName
        self.jobTitle = jobTitle
        self.departmentTitle = departmentTitle
        self.departmentGroup = departmentGroup
        self.personnelNumber = personnelNumber
        self.city = city
        self.personalPhone = personalPhone
        self.workEmail = workEmail
        self.vehicleModel = vehicleModel
        self.vehiclePlate = vehiclePlate
        self.vehicleVin = vehicleVin
        self.vehicleSts = vehicleSts
        self.vehiclePts = vehiclePts
        self.vehicleColor = vehicleColor
        self.engineVolumeCm3 = engineVolumeCm3
        self.enginePowerHp = enginePowerHp
        self.initialMileageKm = initialMileageKm
        self.routeWarehouseAddress = routeWarehouseAddress
        self.routeHomeAddress = routeHomeAddress
    }

    public static let empty = UserProfileData()

    public var fullName: String? {
        [lastName, firstName]
            .compactMap(Self.clean)
            .joined(separator: " ")
            .nilIfBlank
    }

    public var shortDisplayName: String? {
        Self.clean(firstName) ?? fullName
    }

    public var requestBody: [String: String] {
        [
            "firstName": firstName,
            "lastName": lastName,
            "middleName": middleName,
            "jobTitle": jobTitle,
            "departmentTitle": departmentTitle,
            "departmentGroup": departmentGroup,
            "personnelNumber": personnelNumber,
            "city": city,
            "personalPhone": personalPhone,
            "workEmail": workEmail,
            "vehicleModel": vehicleModel,
            "vehiclePlate": vehiclePlate,
            "vehicleVin": vehicleVin,
            "vehicleSts": vehicleSts,
            "vehiclePts": vehiclePts,
            "vehicleColor": vehicleColor,
            "engineVolumeCm3": engineVolumeCm3,
            "enginePowerHp": enginePowerHp,
            "initialMileageKm": initialMileageKm,
            "routeWarehouseAddress": routeWarehouseAddress,
            "routeHomeAddress": routeHomeAddress
        ].mapValues { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    }

    public nonisolated static func clean(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}

public struct AppSession: Codable, Hashable, Sendable {
    public var token: String
    public var user: AppUser

    public init(token: String, user: AppUser) {
        self.token = token
        self.user = user
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
