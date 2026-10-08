import Foundation

public enum AppNetworkBannerKind: String, Hashable, Sendable {
    case networkUnavailable
    case connectionLost
    case serverUnavailable
    case cannotConnectToServer

    public var message: String {
        switch self {
        case .networkUnavailable:
            return "Нет подключения к интернету"
        case .connectionLost:
            return "Соединение прервано"
        case .serverUnavailable:
            return "Сервер не отвечает"
        case .cannotConnectToServer:
            return "Не удалось подключиться к серверу"
        }
    }
}

public enum AppErrorClassification {
    public enum Classification {
        case cancellation
        case network(AppNetworkBannerKind)
        case domain
    }

    public static func classification(for error: Error) -> Classification {
        if error is CancellationError {
            return .cancellation
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSUserCancelledError {
            return .cancellation
        }
        if nsError.domain == NSURLErrorDomain {
            return classification(forURLCode: URLError.Code(rawValue: nsError.code))
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            let underlyingClassification = classification(for: underlyingError)
            if case .domain = underlyingClassification {
                // Keep checking the outer error.
            } else {
                return underlyingClassification
            }
        }

        return classification(forMessage: nsError.localizedDescription)
    }

    public static func classification(forMessage message: String) -> Classification {
        let normalized = normalizedMessage(message)
        guard !normalized.isEmpty else { return .domain }

        let cancellationFragments = [
            "отменено",
            "операция отменена",
            "cancelled",
            "canceled",
            "request was cancelled",
            "request was canceled",
            "nsurlerrorcancelled",
            "nsurlerrordomain code=-999",
            "код -999"
        ]
        if cancellationFragments.contains(where: normalized.contains) {
            return .cancellation
        }

        let timeoutFragments = [
            "timed out",
            "timeout",
            "превышено время ожидания",
            "не ответил вовремя",
            "сервер не отвечает",
            "http 408",
            "http 502",
            "http 503",
            "http 504",
            "(408)",
            "(502)",
            "(503)",
            "(504)"
        ]
        if timeoutFragments.contains(where: normalized.contains) {
            return .network(.serverUnavailable)
        }

        let lostConnectionFragments = [
            "network connection was lost",
            "соединение с интернетом прервано",
            "соединение прервано",
            "потеряно соединение"
        ]
        if lostConnectionFragments.contains(where: normalized.contains) {
            return .network(.connectionLost)
        }

        let noInternetFragments = [
            "internet connection appears to be offline",
            "not connected to the internet",
            "интернет-соединение отсутствует",
            "нет подключения к интернету",
            "сети нет"
        ]
        if noInternetFragments.contains(where: normalized.contains) {
            return .network(.networkUnavailable)
        }

        let cannotConnectFragments = [
            "cannot connect to host",
            "cannot find host",
            "dns lookup failed",
            "не удалось подключиться",
            "не удалось найти сервер",
            "сервер недоступен",
            "проблема с подключением",
            "ошибка сети"
        ]
        if cannotConnectFragments.contains(where: normalized.contains) {
            return .network(.cannotConnectToServer)
        }

        return .domain
    }

    public static func isCancellation(_ error: Error) -> Bool {
        if case .cancellation = classification(for: error) {
            return true
        }
        return false
    }

    public static func isDomainMessage(_ message: String) -> Bool {
        if case .domain = classification(forMessage: message) {
            return true
        }
        return false
    }

    private static func classification(forURLCode code: URLError.Code) -> Classification {
        switch code {
        case .cancelled, .userCancelledAuthentication:
            return .cancellation
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .network(.networkUnavailable)
        case .networkConnectionLost, .backgroundSessionWasDisconnected:
            return .network(.connectionLost)
        case .timedOut,
             .badServerResponse,
             .cannotLoadFromNetwork,
             .httpTooManyRedirects,
             .redirectToNonExistentLocation,
             .zeroByteResource:
            return .network(.serverUnavailable)
        case .cannotFindHost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .network(.cannotConnectToServer)
        default:
            return .domain
        }
    }

    private static func normalizedMessage(_ message: String) -> String {
        message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased()
    }

}
