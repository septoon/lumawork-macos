import Foundation
import EngineerCore

struct WikiArticleDocument {
    let title: String
    let section: String
    let sourceURL: String
    let convertedAt: String?
    let blocks: [WikiArticleBlock]

    init(article: WikiArticle) {
        let rawLines = article.content
            .replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
        var lines = Self.removingFrontMatter(from: rawLines)

        let extractedTitle = Self.firstValue(prefix: "#", in: lines) ?? article.title
        let extractedSection = Self.metadataValue(prefix: "Раздел:", in: lines) ?? article.section
        let extractedSource = Self.metadataValue(prefix: "Источник:", in: lines) ?? article.sourceUrl
        let extractedDate = Self.metadataValue(prefix: "Дата конвертации:", in: lines)

        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "---" ||
                trimmed == "# \(extractedTitle)" ||
                trimmed.hasPrefix("Источник:") ||
                trimmed.hasPrefix("Раздел:") ||
                trimmed.hasPrefix("Дата конвертации:")
        }

        self.title = extractedTitle
        self.section = extractedSection
        self.sourceURL = extractedSource
        self.convertedAt = extractedDate?.wikiShortDate
        self.blocks = Self.parseBlocks(lines)
    }

    private static func parseBlocks(_ lines: [String]) -> [WikiArticleBlock] {
        var blocks: [WikiArticleBlock] = []
        var paragraph = [String]()
        var bullets = [String]()
        var imageOrdinal = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: " ").wikiCleanText
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(text: text, isImportant: text.localizedCaseInsensitiveContains("ВАЖНО")))
        }

        func flushBullets() {
            let cleaned = bullets.map(\.wikiCleanText).filter { !$0.isEmpty }
            bullets.removeAll()
            guard !cleaned.isEmpty else { return }
            blocks.append(.bullets(cleaned))
        }

        for line in lines {
            var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                flushParagraph()
                flushBullets()
                continue
            }

            if let imageTitle = trimmed.wikiImageTitle {
                flushParagraph()
                flushBullets()
                blocks.append(.image(title: imageTitle, ordinal: imageOrdinal))
                imageOrdinal += 1

                let remainingText = trimmed.wikiRemovingImageMarkup.wikiCleanText
                if !remainingText.isEmpty {
                    paragraph.append(remainingText)
                }
                continue
            }

            let lineWithoutImageWrapper = trimmed.wikiRemovingImageWrapperPrefix
            if lineWithoutImageWrapper != trimmed {
                flushParagraph()
                flushBullets()
                trimmed = lineWithoutImageWrapper
                guard !trimmed.isEmpty else { continue }
            }

            if trimmed.hasPrefix("## ") || trimmed.hasPrefix("### ") {
                flushParagraph()
                flushBullets()
                let level = trimmed.hasPrefix("### ") ? 3 : 2
                blocks.append(.heading(level: level, title: trimmed.replacingOccurrences(of: #"^#{2,3}\s+"#, with: "", options: .regularExpression).wikiCleanText))
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }

            if trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                flushParagraph()
                bullets.append(trimmed.replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression))
                continue
            }

            paragraph.append(trimmed)
        }

        flushParagraph()
        flushBullets()
        return blocks.isEmpty ? [.paragraph(text: "Статья не содержит распознанного текста.", isImportant: false)] : blocks
    }

    private static func removingFrontMatter(from lines: [String]) -> [String] {
        guard let openingIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }), lines[openingIndex].trimmingCharacters(in: .whitespacesAndNewlines) == "---" else {
            return lines
        }

        guard let closingIndex = lines.indices.dropFirst(openingIndex + 1).first(where: {
            lines[$0].trimmingCharacters(in: .whitespacesAndNewlines) == "---"
        }) else {
            return lines
        }

        return Array(lines.dropFirst(closingIndex + 1))
    }

    private static func metadataValue(prefix: String, in lines: [String]) -> String? {
        lines.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstValue(prefix: String, in lines: [String]) -> String? {
        lines.first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix + " ") }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WikiArticleBlock: Identifiable {
    case heading(level: Int, title: String)
    case paragraph(text: String, isImportant: Bool)
    case bullets([String])
    case image(title: String, ordinal: Int)

    var id: String {
        switch self {
        case .heading(let level, let title):
            return "h\(level)-\(title)"
        case .paragraph(let text, let isImportant):
            return "p\(isImportant)-\(text.prefix(40))"
        case .bullets(let items):
            return "b-\(items.joined(separator: "|").prefix(40))"
        case .image(let title, let ordinal):
            return "i-\(ordinal)-\(title)"
        }
    }
}

private extension String {
    var wikiCleanText: String {
        var value = self
            .replacingOccurrences(of: #"\[!\[[^\]]*\]\([^)]+\)\]\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"!\[[^\]]*\]\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[\]\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:>\s*)*\]\(https?://[^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"_([^_]+)_"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        value = value.replacingOccurrences(of: "ВАЖНО!", with: "ВАЖНО:")
        return value
    }

    var wikiImageTitle: String? {
        if range(of: #"\[\]\([^)]+\)"#, options: .regularExpression) != nil {
            return "Изображение"
        }

        let patterns = [
            #"\[!\[([^\]]*)\]\([^)]+\)\]\([^)]+\)"#,
            #"!\[([^\]]*)\]\([^)]+\)"#
        ]

        for pattern in patterns {
            guard let range = range(of: pattern, options: .regularExpression) else { continue }
            let raw = String(self[range])
                .replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
                .wikiCleanText
            return raw.isEmpty ? "Изображение" : raw
        }

        return nil
    }

    var wikiRemovingImageMarkup: String {
        replacingOccurrences(
            of: #"\[!\[[^\]]*\]\([^)]+\)\]\([^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"\[\]\([^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .wikiRemovingImageWrapperPrefix
    }

    var wikiRemovingImageWrapperPrefix: String {
        let source = trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLink = source.replacingOccurrences(
            of: #"^(?:>\s*)*\]\(https?://[^)]+\)"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        let meaningfulText = withoutLink
            .replacingOccurrences(of: #"[>\[\]\\*_;⇒→.\-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !meaningfulText.isEmpty else { return "" }
        guard withoutLink != source else { return source }

        return withoutLink
            .replacingOccurrences(of: #"^[>\[\]\\;⇒→.]+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var wikiShortDate: String {
        replacingOccurrences(of: #"T.*$"#, with: "", options: .regularExpression)
    }
}
