import Foundation

public enum SimpleOneRequestSource: String, Codable, Hashable, Sendable {
    case active
    case closed
}

public struct SimpleOneRequestRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: String {
        sysID.isEmpty ? number : sysID
    }

    public var source: SimpleOneRequestSource
    public var sysID: String
    public var number: String
    public var incomingNumber: String
    public var registeredAt: String? = nil
    public var waitingReason: String? = nil
    public var state: String
    public var stateRaw: String? = nil
    public var shortDescription: String
    public var assignmentGroup: String
    public var initiator: String? = nil
    public var priority: String? = nil
    public var clientServiceParent: String? = nil
    public var clientService: String? = nil
    public var requestType: String
    public var address: String
    public var customer: String
    public var deadline: String
    public var resolvedAt: String
    public var completedAt: String? = nil
    public var closedAt: String? = nil
    public var assignedUser: String
    public var assignedUserID: String? = nil
    public var sysUpdatedAt: String? = nil
    public var terminalModel: String
    public var terminalID: String
    public var contactPerson: String
    public var contactPhone: String? = nil
    public var engineerComment: String
    public var closureCode: String? = nil
    public var resolution: String? = nil
    public var additionalInformation: String? = nil
    public var description: String
    public var installedFiscalStorageSerialNumber: String? = nil
    public var ofdTariffActivationCode: String? = nil
    public var usedSIMCard: String? = nil
    public var tableFields: [ClosedRequestInfoField]? = nil

    public var primaryDate: String {
        source == .active ? deadline : resolvedAt
    }

    public var informationText: String {
        [
            additionalInformation ?? "",
            description
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    public var searchText: String {
        let primaryValues: [String] = [
            number,
            incomingNumber,
            registeredAt ?? "",
            waitingReason ?? "",
            state,
            stateRaw ?? "",
            shortDescription,
            assignmentGroup,
            initiator ?? "",
            priority ?? "",
            clientServiceParent ?? "",
            clientService ?? "",
            requestType,
            address,
            customer,
            deadline,
            resolvedAt,
            completedAt ?? "",
            closedAt ?? "",
            assignedUser,
            terminalModel,
            terminalID,
            contactPerson,
            contactPhone ?? ""
        ]
        let secondaryValues: [String] = [
            engineerComment,
            closureCode ?? "",
            resolution ?? "",
            additionalInformation ?? "",
            description,
            installedFiscalStorageSerialNumber ?? "",
            ofdTariffActivationCode ?? "",
            usedSIMCard ?? ""
        ]
        let tableValues = (tableFields ?? [])
            .flatMap { [$0.key, $0.value] }
        let values = primaryValues + secondaryValues + tableValues
        return values
            .joined(separator: "\n")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

public extension SimpleOneRequestRecord {
    var deadlineDate: Date? {
        Self.parseSimpleOneDate(deadline)
    }

    var registeredDate: Date? {
        Self.parseSimpleOneDate(registeredAt ?? "")
    }

    var isOverdue: Bool {
        guard source == .active, let deadlineDate else { return false }
        return deadlineDate < Date()
    }

    var slaStatusText: String? {
        guard let deadlineDate else { return nil }
        let interval = deadlineDate.timeIntervalSinceNow
        let prefix = interval < 0 ? "Просрочено на" : "Осталось"
        let absolute = abs(interval)
        let hours = Int(absolute) / 3_600
        let minutes = (Int(absolute) % 3_600) / 60

        if hours >= 24 {
            let days = hours / 24
            let remainingHours = hours % 24
            return "\(prefix) \(days) дн. \(remainingHours) ч."
        }
        if hours > 0 {
            return "\(prefix) \(hours) ч. \(minutes) мин."
        }
        return "\(prefix) \(max(minutes, 1)) мин."
    }

    private static func parseSimpleOneDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let date = simpleOneDateFormatters.lazy.compactMap({ $0.date(from: trimmed) }).first else {
            return nil
        }

        // SimpleOne uses the Unix epoch as an empty date in some request fields.
        guard Calendar(identifier: .gregorian).component(.year, from: date) > 1970 else {
            return nil
        }

        return date
    }

    private static let simpleOneDateFormatters: [DateFormatter] = [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "dd.MM.yyyy HH:mm:ss",
        "dd.MM.yyyy HH:mm",
        "MM.dd.yyyy HH:mm:ss",
        "MM.dd.yyyy HH:mm"
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}


public struct ClosedRequestInfoField: Codable, Hashable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}
