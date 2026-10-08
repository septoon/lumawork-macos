import Foundation

public struct AppConfig {
    public let wikiAPIOrigin: String?
    public let wikiAPIToken: String?
    public let lumaWorkAPIOrigin: String?
    public let simpleOneAPIOrigin: String?
    public let simpleOneWebOrigin: String?
    public let appSiteOrigin: String?
    public let fuelArchiveOwnerEmail: String?
    public let supportEmail: String?
    public let telegramAppURL: String?
    public let telegramWebURL: String?
    public let mapsRouteURL: String?

    public init(
        wikiAPIOrigin: String? = AppConfig.resolveFirst("WIKI_API_URL", "WIKI_API_ORIGIN"),
        wikiAPIToken: String? = AppConfig.resolveFirst("WIKI_API_TOKEN"),
        lumaWorkAPIOrigin: String? = AppConfig.resolveFirst("LUMAWORK_API_URL", "LUMAWORK_API_ORIGIN"),
        simpleOneAPIOrigin: String? = AppConfig.resolveFirst("SIMPLEONE_API_URL", "SIMPLEONE_API_ORIGIN"),
        simpleOneWebOrigin: String? = AppConfig.resolveFirst("SIMPLEONE_WEB_URL", "SIMPLEONE_WEB_ORIGIN"),
        appSiteOrigin: String? = AppConfig.resolveFirst("APP_SITE_URL", "APP_SITE_ORIGIN"),
        fuelArchiveOwnerEmail: String? = AppConfig.resolveFirst("FUEL_ARCHIVE_OWNER_EMAIL"),
        supportEmail: String? = AppConfig.resolveFirst("SUPPORT_EMAIL"),
        telegramAppURL: String? = AppConfig.resolveFirst("TELEGRAM_APP_URL"),
        telegramWebURL: String? = AppConfig.resolveFirst("TELEGRAM_WEB_URL"),
        mapsRouteURL: String? = AppConfig.resolveFirst("MAPS_ROUTE_URL")
    ) {
        self.wikiAPIOrigin = wikiAPIOrigin
        self.wikiAPIToken = wikiAPIToken
        self.lumaWorkAPIOrigin = lumaWorkAPIOrigin
        self.simpleOneAPIOrigin = simpleOneAPIOrigin
        self.simpleOneWebOrigin = simpleOneWebOrigin
        self.appSiteOrigin = appSiteOrigin
        self.fuelArchiveOwnerEmail = fuelArchiveOwnerEmail
        self.supportEmail = supportEmail
        self.telegramAppURL = telegramAppURL
        self.telegramWebURL = telegramWebURL
        self.mapsRouteURL = mapsRouteURL
    }

    public static func configuredURL(_ rawValue: String?) -> URL {
        guard let rawValue,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    public static func resolveFirst(_ keys: String...) -> String? {
        resolve(
            keys: keys,
            environment: ProcessInfo.processInfo.environment,
            bundleValues: Dictionary(uniqueKeysWithValues: Set(keys).map { ($0, Bundle.main.object(forInfoDictionaryKey: $0) as? String) }),
            defaultValues: Dictionary(uniqueKeysWithValues: Set(keys).map { ($0, UserDefaults.standard.string(forKey: $0)) })
        )
    }

    public static func resolve(
        keys: [String],
        environment: [String: String],
        bundleValues: [String: String?],
        defaultValues: [String: String?]
    ) -> String? {
        let candidates: [String?] = keys.flatMap { key in
            [environment[key], bundleValues[key] ?? nil, defaultValues[key] ?? nil]
        }
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("$(") })
    }

    public static func validatedURL(_ rawValue: String?) throws -> URL {
        let url = configuredURL(rawValue)
        guard !url.isFileURL else {
            throw AppServiceError.message("Не настроен адрес сервера.")
        }
        return url
    }
}
