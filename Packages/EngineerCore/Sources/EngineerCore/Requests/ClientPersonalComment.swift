import Foundation

public struct ClientPersonalComment: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var normalizedTIN: String
    public var displayTIN: String
    public var targets: [ClientPersonalCommentTarget]
    public var terminalIDs: [String]
    public var contactPerson: String
    public var phone: String
    public var email: String
    public var extraInfo: String?
    public var authorShortName: String?
    public var updatedAt: Date

    init(
        id: String,
        normalizedTIN: String,
        displayTIN: String,
        targets: [ClientPersonalCommentTarget],
        terminalIDs: [String],
        contactPerson: String,
        phone: String,
        email: String,
        extraInfo: String?,
        authorShortName: String?,
        updatedAt: Date
    ) {
        self.id = id
        self.normalizedTIN = normalizedTIN
        self.displayTIN = displayTIN
        self.targets = targets
        self.terminalIDs = terminalIDs
        self.contactPerson = contactPerson
        self.phone = phone
        self.email = email
        self.extraInfo = extraInfo
        self.authorShortName = authorShortName
        self.updatedAt = updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let displayTIN = try container.decodeIfPresent(String.self, forKey: .displayTIN) ?? ""
        let normalizedTIN = try container.decodeIfPresent(String.self, forKey: .normalizedTIN)
            ?? ClientPersonalCommentMatchingIndex.normalizedTIN(displayTIN)

        let targets = try container.decodeIfPresent([ClientPersonalCommentTarget].self, forKey: .targets) ?? []
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? Self.storageKey(normalizedTIN: normalizedTIN, targets: targets)
        self.normalizedTIN = normalizedTIN
        self.displayTIN = displayTIN
        self.targets = targets
        self.terminalIDs = try container.decodeIfPresent([String].self, forKey: .terminalIDs) ?? []
        self.contactPerson = try container.decodeIfPresent(String.self, forKey: .contactPerson) ?? ""
        self.phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? ""
        self.email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        self.extraInfo = try container.decodeIfPresent(String.self, forKey: .extraInfo)
        self.authorShortName = try container.decodeIfPresent(String.self, forKey: .authorShortName)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    static func storageKey(normalizedTIN: String, targets: [ClientPersonalCommentTarget]) -> String {
        let targetKey = targets.isEmpty
            ? "all"
            : targets.map(\.normalizedKey).sorted().joined(separator: "||")
        return "\(normalizedTIN)#\(targetKey)"
    }
}

public struct ClientPersonalCommentTarget: Codable, Hashable, Identifiable, Sendable {
    public init(address: String) { self.address = address }
    public var address: String

    public var id: String { normalizedKey }

    public var normalizedKey: String {
        ClientPersonalCommentMatchingIndex.normalizedScopeText(address)
    }

    public var displayText: String {
        let addressText = address.trimmingCharacters(in: .whitespacesAndNewlines)
        return addressText.isEmpty ? "Адрес не указан" : addressText
    }

    func matches(address rawAddress: String) -> Bool {
        let ownAddress = Self.normalized(address)
        let incomingAddress = Self.normalized(rawAddress)
        guard !ownAddress.isEmpty, !incomingAddress.isEmpty else {
            return ownAddress.isEmpty
        }
        return ownAddress == incomingAddress
    }

    private static func normalized(_ raw: String) -> String {
        ClientPersonalCommentMatchingIndex.normalizedScopeText(raw)
    }
}

public struct ClientPersonalCommentDraft: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var serverID: String?
    public var sourceCommentID: String?
    public var tin = ""
    public var targets: [ClientPersonalCommentTarget] = []
    public var terminalIDs: [String] = []
    public var contactPerson = ""
    public var phone = "+7 "
    public var email = ""
    public var extraInfo = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        serverID = try container.decodeIfPresent(String.self, forKey: .serverID)
        sourceCommentID = try container.decodeIfPresent(String.self, forKey: .sourceCommentID)
        tin = try container.decodeIfPresent(String.self, forKey: .tin) ?? ""
        targets = try container.decodeIfPresent([ClientPersonalCommentTarget].self, forKey: .targets) ?? []
        terminalIDs = try container.decodeIfPresent([String].self, forKey: .terminalIDs) ?? []
        contactPerson = try container.decodeIfPresent(String.self, forKey: .contactPerson) ?? ""
        phone = try container.decodeIfPresent(String.self, forKey: .phone) ?? "+7 "
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        extraInfo = try container.decodeIfPresent(String.self, forKey: .extraInfo) ?? ""
    }

    public init(comment: ClientPersonalComment, fallbackTIN: String = "") {
        id = UUID()
        serverID = comment.id
        sourceCommentID = nil
        tin = comment.displayTIN.isEmpty ? fallbackTIN : comment.displayTIN
        targets = comment.targets
        terminalIDs = comment.terminalIDs
        contactPerson = comment.contactPerson
        phone = comment.phone.isEmpty ? "+7" : ClientPersonalCommentPhoneFormatter.canonical(comment.phone)
        email = comment.email
        extraInfo = comment.extraInfo ?? ""
    }

    public var normalizedTIN: String {
        ClientPersonalCommentMatchingIndex.normalizedTIN(tin)
    }

    public var selectedTargetKeys: Set<String> {
        Set(targets.map(\.normalizedKey))
    }

    public var canSave: Bool {
        !normalizedTIN.isEmpty
            && (!contactPerson.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !normalizedPhoneDigits.isEmpty
                || !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !extraInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    public var normalizedPhone: String {
        ClientPersonalCommentPhoneFormatter.canonical(phone)
    }

    private var normalizedPhoneDigits: String {
        String(normalizedPhone.dropFirst(2))
    }
}
