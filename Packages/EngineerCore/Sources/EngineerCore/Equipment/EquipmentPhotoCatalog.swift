import Foundation

public struct EquipmentPhoto: Codable, Hashable, Sendable {
    public let referenceName: String
    public let aliases: [String]
    public let url: URL?
}

public enum EquipmentPhotoCatalog {
    static func fallbackPhotos(origin: URL) -> [EquipmentPhoto] { [
        photo("Стационарный Unitodi MF960 AL", origin: origin, file: "unitodi-mf960-stationary.webp"),
        photo(
            "Переносной Unitodi MF 960",
            origin: origin, file: "unitodi-mf960-portable.webp",
            aliases: ["Переносной POS-терминал MoreFun UniTodi 960 AL"]
        ),
        photo("Внешняя PIN-клавиатура MoreFun Vanstone (Aisino) UniTodi V10", origin: origin, file: "unitodi-v10.webp"),
        photo("AISINO V73", origin: origin, file: "aisino-v73.webp"),
        photo("Feitian F20", origin: origin, file: "feitian-f20.webp"),
        photo("PAX AF6", origin: origin, file: "pax-af6.webp"),
        photo("Pax D190", origin: origin, file: "pax-d190.webp"),
        photo("Pax D200", origin: origin, file: "pax-d200.webp"),
        photo("Pax D230", origin: origin, file: "pax-d230.webp"),
        photo("Pax D270", origin: origin, file: "pax-d270.webp"),
        photo("Pax Q25", origin: origin, file: "pax-q25.webp"),
        photo("Pax S200", origin: origin, file: "pax-s200.webp"),
        photo("PAX S210", origin: origin, file: "pax-s210.webp"),
        photo("Pax S300", origin: origin, file: "pax-s300.webp"),
        photo("Pax S920", origin: origin, file: "pax-s920.webp"),
        photo(
            "UniTodi P8",
            origin: origin, file: "unitodi-p8.webp",
            aliases: ["Интеллектуальный PIN-PAD Telepower UniTodi P8Bio"]
        )
    ] }

    public static func match(
        for itemName: String,
        in photos: [EquipmentPhoto]
    ) -> EquipmentPhoto? {
        let normalizedItemName = normalizedName(itemName)
        if let exactMatch = photos.first(where: { photo in
            ([photo.referenceName] + photo.aliases).contains { normalizedName($0) == normalizedItemName }
        }) {
            return exactMatch
        }

        let itemFingerprint = TerminalNameFingerprint(itemName)
        return photos
            .compactMap { photo -> (EquipmentPhoto, Int)? in
                let referenceFingerprint = TerminalNameFingerprint(photo.referenceName)
                guard let score = itemFingerprint.matchScore(with: referenceFingerprint) else { return nil }
                return (photo, score)
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    public static func match(
        for candidateNames: [String],
        in photos: [EquipmentPhoto]
    ) -> EquipmentPhoto? {
        for name in candidateNames {
            if let match = match(for: name, in: photos) { return match }
        }
        return nil
    }

    private static func photo(
        _ referenceName: String,
        origin: URL,
        file: String,
        aliases: [String] = []
    ) -> EquipmentPhoto {
        let root = origin
            .appendingPathComponent("uploads", isDirectory: true)
            .appendingPathComponent("vehicle-images", isDirectory: true)
            .appendingPathComponent("backpack-terminals", isDirectory: true)
        let url = root
            .appendingPathComponent(file)
            .appending(queryItems: [URLQueryItem(name: "v", value: "20260716")])
        return EquipmentPhoto(referenceName: referenceName, aliases: aliases, url: url)
    }

    private static func normalizedName(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct EquipmentPhotoManifest: Decodable, Sendable {
    let version: Int64?
    let items: [Item]

    struct Item: Decodable, Sendable {
        let id: String
        let referenceName: String
        let aliases: [String]
        let fileName: String?
        let url: String?
        let imageUrl: String?
        let revision: Int64?

        private enum CodingKeys: String, CodingKey {
            case id
            case referenceName
            case aliases
            case fileName
            case url
            case imageUrl
            case revision
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            referenceName = try container.decode(String.self, forKey: .referenceName)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? referenceName
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            imageUrl = try container.decodeIfPresent(String.self, forKey: .imageUrl)
            revision = try container.decodeIfPresent(Int64.self, forKey: .revision)
        }

        func photo(relativeTo origin: URL) -> EquipmentPhoto? {
            let name = referenceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }

            let rawURL = (url ?? imageUrl)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedURL: URL?
            if let rawURL, !rawURL.isEmpty {
                resolvedURL = URL(string: rawURL, relativeTo: origin)?.absoluteURL
            } else if let fileName, !fileName.isEmpty {
                let imageURL = origin
                    .appendingPathComponent("uploads", isDirectory: true)
                    .appendingPathComponent("vehicle-images", isDirectory: true)
                    .appendingPathComponent("backpack-terminals", isDirectory: true)
                    .appendingPathComponent(fileName)
                if let revision {
                    resolvedURL = imageURL.appending(queryItems: [URLQueryItem(name: "v", value: String(revision))])
                } else {
                    resolvedURL = imageURL
                }
            } else {
                resolvedURL = nil
            }

            return EquipmentPhoto(referenceName: name, aliases: aliases, url: resolvedURL)
        }
    }
}


private struct TerminalNameFingerprint {
    private static let brands: Set<String> = ["aisino", "feitian", "morefun", "pax", "unitodi", "vanstone"]
    private static let variants: Set<String> = ["внешняя", "переносной", "стационарный"]

    let terms: Set<String>
    let brandTerms: Set<String>
    let modelTerms: Set<String>
    let variantTerms: Set<String>

    init(_ raw: String) {
        let folded = raw
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ru_RU"))
            .lowercased()
        let tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var models = Set(tokens.filter { token in
            token.contains(where: \.isLetter) && token.contains(where: \.isNumber)
        })
        for index in tokens.indices.dropLast() {
            let prefix = tokens[index]
            let suffix = tokens[tokens.index(after: index)]
            if prefix.allSatisfy(\.isLetter), prefix.count <= 3, suffix.allSatisfy(\.isNumber) {
                models.insert(prefix + suffix)
            }
        }

        let tokenSet = Set(tokens)
        terms = tokenSet
        brandTerms = tokenSet.intersection(Self.brands)
        modelTerms = models
        variantTerms = tokenSet.intersection(Self.variants)
    }

    func matchScore(with reference: TerminalNameFingerprint) -> Int? {
        let matchingModels = modelTerms.intersection(reference.modelTerms)
        guard !matchingModels.isEmpty else { return nil }

        let brandScore = brandTerms.intersection(reference.brandTerms).count * 30
        let modelScore = matchingModels.count * 100
        let variantScore = variantTerms.intersection(reference.variantTerms).count * 25
        let termScore = terms.intersection(reference.terms).count * 2
        return modelScore + brandScore + variantScore + termScore
    }
}


public struct EquipmentPhotoService {
    let origin: URL
    public init(config: AppConfig) { origin = AppConfig.configuredURL(config.lumaWorkAPIOrigin) }
    public func manifest(office: Bool) async throws -> [EquipmentPhoto] {
        let url = origin.appendingPathComponent("api/v2/media/" + (office ? "equipment" : "backpack-terminals"))
        let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await session.data(for: request); try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GsmFuelError.invalidResponse }
        let manifest = try JSONDecoder().decode(EquipmentPhotoManifest.self, from: data)
        return manifest.items.compactMap { $0.photo(relativeTo: origin) }
    }
    public func fallback(office: Bool) -> [EquipmentPhoto] { office ? [] : EquipmentPhotoCatalog.fallbackPhotos(origin: origin) }
}
