import Foundation

public enum EngineerSection: String, CaseIterable, Identifiable {
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

    public var id: String { rawValue }

    public static func availableCases(isAdmin: Bool) -> [EngineerSection] {
        allCases.filter { section in
            section != .users || isAdmin
        }
    }

    public var title: String {
        switch self {
        case .home:
            "Главная"
        case .backpack:
            "Мой рюкзак"
        case .employees:
            "Сотрудники"
        case .maintenance:
            "Авто"
        case .fuel:
            "Топливо"
        case .wiki:
            "Помощник"
        case .ftp:
            "FTP"
        case .salary:
            "Зарплата"
        case .requests:
            "Заявки"
        case .coordination:
            "Координация"
        case .timeReport:
            "Трудозатраты"
        case .analytics:
            "Аналитика"
        case .users:
            "Админка"
        }
    }

    public var subtitle: String {
        switch self {
        case .home:
            "Маршрут инженера"
        case .backpack:
            "Оборудование ЗИП"
        case .employees:
            "Команда и контакты"
        case .maintenance:
            "Автомобили и обслуживание"
        case .fuel:
            "Лимиты и заправки"
        case .wiki:
            "Помощник и база знаний"
        case .ftp:
            "Файлы Сервионики"
        case .salary:
            "Выплаты и документы"
        case .requests:
            "SimpleOne и архив"
        case .coordination:
            "Инженеры и активные заявки"
        case .timeReport:
            "Работа и дорога"
        case .analytics:
            "Сводка заявок"
        case .users:
            "Контроль приложения и сервера"
        }
    }

    public var systemImage: String {
        switch self {
        case .home:
            "house.fill"
        case .backpack:
            "backpack.fill"
        case .employees:
            "person.2.fill"
        case .maintenance:
            "car.fill"
        case .fuel:
            "fuelpump.fill"
        case .wiki:
            "bubble.left.and.text.bubble.right.fill"
        case .ftp:
            "externaldrive.connected.to.line.below.fill"
        case .salary:
            "rublesign.circle.fill"
        case .requests:
            "checklist.checked"
        case .coordination:
            "person.line.dotted.person.fill"
        case .timeReport:
            "clock.badge.checkmark.fill"
        case .analytics:
            "chart.bar.xaxis"
        case .users:
            "person.3.fill"
        }
    }
}
