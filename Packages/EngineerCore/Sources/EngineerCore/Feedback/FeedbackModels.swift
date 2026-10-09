import Foundation

public enum FeedbackKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case error = "ERROR"
    case improvement = "IMPROVEMENT"
    case freeze = "FREEZE"
    case slowdown = "SLOWDOWN"
    case longLoading = "LONG_LOADING"
    case inconvenientInterface = "UI_INCONVENIENT"
    case inappropriateInterface = "UI_INAPPROPRIATE"
    case other = "OTHER"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .error: "Ошибка"
        case .improvement: "Предложение по улучшению"
        case .freeze: "Зависание или фриз"
        case .slowdown: "Торможение"
        case .longLoading: "Долгая загрузка"
        case .inconvenientInterface: "Неудобный интерфейс"
        case .inappropriateInterface: "Неуместный элемент интерфейса"
        case .other: "Другое"
        }
    }

    public var systemImage: String {
        switch self {
        case .error: "exclamationmark.triangle.fill"
        case .improvement: "lightbulb.fill"
        case .freeze: "snowflake"
        case .slowdown: "tortoise.fill"
        case .longLoading: "hourglass"
        case .inconvenientInterface: "hand.raised.fill"
        case .inappropriateInterface: "rectangle.badge.xmark"
        case .other: "ellipsis.circle.fill"
        }
    }

    public var needsReproductionSteps: Bool {
        switch self {
        case .error, .freeze, .slowdown, .longLoading:
            true
        default:
            false
        }
    }
}

public enum FeedbackImpact: String, CaseIterable, Codable, Sendable, Identifiable {
    case minor = "MINOR"
    case interferes = "INTERFERES"
    case blocks = "BLOCKS"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .minor: "Незначительно"
        case .interferes: "Мешает работе"
        case .blocks: "Работа невозможна"
        }
    }
}

public enum FeedbackFrequency: String, CaseIterable, Codable, Sendable, Identifiable {
    case once = "ONCE"
    case sometimes = "SOMETIMES"
    case always = "ALWAYS"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .once: "Один раз"
        case .sometimes: "Иногда"
        case .always: "Всегда"
        }
    }
}

public enum FeedbackStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case draft = "DRAFT"
    case new = "NEW"
    case inProgress = "IN_PROGRESS"
    case resolved = "RESOLVED"
    case closed = "CLOSED"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .draft: "Черновик"
        case .new: "Новое"
        case .inProgress: "В работе"
        case .resolved: "Решено"
        case .closed: "Закрыто"
        }
    }

}

public enum FeedbackPriority: String, Codable, Sendable, CaseIterable, Identifiable {
    case low = "LOW"
    case normal = "NORMAL"
    case high = "HIGH"
    case critical = "CRITICAL"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .low: "Низкий"
        case .normal: "Обычный"
        case .high: "Высокий"
        case .critical: "Критический"
        }
    }
}

public enum FeedbackEmailStatus: String, Codable, Sendable {
    case notQueued = "NOT_QUEUED"
    case pending = "PENDING"
    case sending = "SENDING"
    case sent = "SENT"
    case failed = "FAILED"

    public var title: String {
        switch self {
        case .notQueued: "Не поставлено в очередь"
        case .pending: "Ожидает отправки"
        case .sending: "Отправляется"
        case .sent: "Письмо отправлено"
        case .failed: "Письмо не отправлено"
        }
    }
}

public enum FeedbackArea: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case home
    case backpack
    case employees
    case maintenance
    case fuel
    case wiki
    case ftp
    case salary
    case requests
    case coordination
    case timeReport
    case analytics
    case users
    case sidebar
    case settings
    case authorization
    case notifications
    case other

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .home: "Главная"
        case .backpack: "Мой рюкзак"
        case .employees: "Сотрудники"
        case .maintenance: "Авто"
        case .fuel: "Топливо"
        case .wiki: "Вики"
        case .ftp: "Файлы"
        case .salary: "Зарплата"
        case .requests: "Заявки"
        case .coordination: "Координация"
        case .timeReport: "Трудозатраты"
        case .analytics: "Аналитика"
        case .users: "Админка"
        case .sidebar: "Боковое меню"
        case .settings: "Настройки"
        case .authorization: "Авторизация"
        case .notifications: "Уведомления"
        case .other: "Другое"
        }
    }

}

public struct FeedbackDeviceInfo: Codable, Sendable, Hashable {
    public init(deviceModel: String, osVersion: String, appVersion: String, language: String, timeZone: String, capturedAt: String) {
        self.deviceModel = deviceModel; self.osVersion = osVersion; self.appVersion = appVersion
        self.language = language; self.timeZone = timeZone; self.capturedAt = capturedAt
    }
    public var deviceModel: String
    public var osVersion: String
    public var appVersion: String
    public var language: String
    public var timeZone: String
    public var capturedAt: String

}

public struct FeedbackAttachment: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var fileName: String
    public var mimeType: String
    public var sizeBytes: Int
    public var width: Int
    public var height: Int
    public var createdAt: Date
}

public struct FeedbackAddition: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var text: String
    public var createdAt: Date
}

public struct FeedbackMessage: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var number: String
    public var kind: FeedbackKind
    public var title: String
    public var message: String
    public var reproductionSteps: String?
    public var expectedResult: String?
    public var areaCodes: [String]
    public var otherArea: String?
    public var impact: FeedbackImpact
    public var frequency: FeedbackFrequency
    public var status: FeedbackStatus
    public var priority: FeedbackPriority
    public var adminNote: String?
    public var reporterEmail: String
    public var reporterName: String?
    public var deviceInfo: FeedbackDeviceInfo?
    public var resubmittedFromId: String?
    public var submittedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?
    public var emailStatus: FeedbackEmailStatus
    public var emailError: String?
    public var attachments: [FeedbackAttachment]
    public var additions: [FeedbackAddition]

    public var areaTitles: String {
        let titles = areaCodes.compactMap { FeedbackArea(rawValue: $0)?.title }
        return (titles + [otherArea].compactMap { $0 }).joined(separator: ", ")
    }

    public var resendDraft: FeedbackDraft {
        FeedbackDraft(
            clientRequestID: UUID(),
            kind: kind,
            title: title,
            message: message,
            reproductionSteps: reproductionSteps ?? "",
            expectedResult: expectedResult ?? "",
            areas: Set(areaCodes.compactMap(FeedbackArea.init(rawValue:))),
            otherArea: otherArea ?? "",
            impact: impact,
            frequency: frequency,
            resubmittedFromID: id
        )
    }
}

public struct FeedbackDraft: Codable, Sendable, Equatable {
    public init(clientRequestID: UUID = UUID(), kind: FeedbackKind = .error, title: String = "", message: String = "", reproductionSteps: String = "", expectedResult: String = "", areas: Set<FeedbackArea> = [], otherArea: String = "", impact: FeedbackImpact = .minor, frequency: FeedbackFrequency = .once, resubmittedFromID: String? = nil) {
        self.clientRequestID = clientRequestID; self.kind = kind; self.title = title; self.message = message
        self.reproductionSteps = reproductionSteps; self.expectedResult = expectedResult; self.areas = areas
        self.otherArea = otherArea; self.impact = impact; self.frequency = frequency; self.resubmittedFromID = resubmittedFromID
    }
    public var clientRequestID = UUID()
    public var kind: FeedbackKind = .error
    public var title = ""
    public var message = ""
    public var reproductionSteps = ""
    public var expectedResult = ""
    public var areas: Set<FeedbackArea> = []
    public var otherArea = ""
    public var impact: FeedbackImpact = .minor
    public var frequency: FeedbackFrequency = .once
    public var resubmittedFromID: String?

    public var hasContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || resubmittedFromID != nil
    }

    public var isValid: Bool {
        validationMessage == nil
    }

    public var validationMessage: String? {
        if areas.isEmpty {
            return "Выберите хотя бы один раздел приложения."
        }
        if areas.contains(.other), otherArea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Укажите название другого раздела."
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count < 5 {
            return "Заголовок должен содержать не меньше 5 символов."
        }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            return "Опишите сообщение подробнее — не меньше 20 символов."
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count > 160 || message.trimmingCharacters(in: .whitespacesAndNewlines).count > 8000 || reproductionSteps.trimmingCharacters(in: .whitespacesAndNewlines).count > 4000 || expectedResult.trimmingCharacters(in: .whitespacesAndNewlines).count > 4000 || otherArea.trimmingCharacters(in: .whitespacesAndNewlines).count > 300 { return "Превышена допустимая длина текста." }
        return nil
    }
}
