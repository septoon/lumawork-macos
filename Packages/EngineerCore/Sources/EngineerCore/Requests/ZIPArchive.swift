import Compression
import Foundation

enum ClosedRequestsImportError: LocalizedError {
    case archive(String)
    case worksheetNotFound
    case xml(String)
    case unsupportedCompressionMethod(Int)
    case decompressionFailed(String)

    var errorDescription: String? {
        switch self {
        case .archive(let message):
            return message
        case .worksheetNotFound:
            return "В файле не найден worksheet с заявками."
        case .xml(let message):
            return message
        case .unsupportedCompressionMethod(let method):
            return "Файл использует неподдерживаемый метод сжатия (\(method))."
        case .decompressionFailed(let name):
            return "Не удалось распаковать часть Excel-файла: \(name)."
        }
    }
}

struct ZIPEntry: Sendable {
    var name: String
    var compressedSize: Int
    var uncompressedSize: Int
    var compressionMethod: Int
    var crc: UInt32
    var localHeaderOffset: Int
}

struct ZIPArchive: Sendable {
    let data: Data
    let entries: [String: ZIPEntry]

    init(data: Data) throws {
        guard data.count <= 128 * 1024 * 1024 else { throw ClosedRequestsImportError.archive("XLSX-файл превышает 128 МБ.") }
        self.data = data
        self.entries = try Self.readEntries(from: data)
    }

    func extract(_ path: String) throws -> Data {
        guard let entry = entries[path] else {
            throw ClosedRequestsImportError.archive("В архиве отсутствует \(path).")
        }

        guard entry.localHeaderOffset >= 0,
              entry.localHeaderOffset <= data.count - 30 else {
            throw ClosedRequestsImportError.archive("Некорректный local header для \(path).")
        }
        guard Self.readUInt32(from: data, at: entry.localHeaderOffset) == 0x04034B50 else {
            throw ClosedRequestsImportError.archive("Поврежден local header для \(path).")
        }

        let fileNameLength = Int(Self.readUInt16(from: data, at: entry.localHeaderOffset + 26))
        let extraFieldLength = Int(Self.readUInt16(from: data, at: entry.localHeaderOffset + 28))
        let payloadStart = entry.localHeaderOffset + 30 + fileNameLength + extraFieldLength
        let payloadEnd = payloadStart + entry.compressedSize

        guard payloadStart >= 0, payloadEnd <= data.count, payloadStart <= payloadEnd else {
            throw ClosedRequestsImportError.archive("Некорректные границы данных для \(path).")
        }

        guard entry.uncompressedSize <= 256 * 1024 * 1024 else { throw ClosedRequestsImportError.archive("Часть XLSX превышает допустимый размер.") }
        let payload = data.subdata(in: payloadStart ..< payloadEnd)
        let result: Data

        switch entry.compressionMethod {
        case 0:
            result = payload
        case 8:
            guard let inflated = Self.inflate(payload, expectedSize: entry.uncompressedSize) else {
                throw ClosedRequestsImportError.decompressionFailed(path)
            }
            result = inflated
        default:
            throw ClosedRequestsImportError.unsupportedCompressionMethod(entry.compressionMethod)
        }
        guard result.count == entry.uncompressedSize, try ZIPWriter.crc32(result) == entry.crc else { throw ClosedRequestsImportError.archive("Контрольная сумма XLSX не совпадает.") }
        return result
    }

    private static func readEntries(from data: Data) throws -> [String: ZIPEntry] {
        guard let eocdOffset = findEndOfCentralDirectory(in: data) else {
            throw ClosedRequestsImportError.archive("Не найден конец central directory.")
        }
        guard eocdOffset <= data.count - 22 else {
            throw ClosedRequestsImportError.archive("Поврежден конец central directory.")
        }

        guard readUInt16(from: data, at: eocdOffset + 4) == 0, readUInt16(from: data, at: eocdOffset + 6) == 0, readUInt16(from: data, at: eocdOffset + 8) == readUInt16(from: data, at: eocdOffset + 10) else { throw ClosedRequestsImportError.archive("Многотомный ZIP не поддерживается.") }
        let centralDirectoryOffset = Int(readUInt32(from: data, at: eocdOffset + 16))
        let totalEntries = Int(readUInt16(from: data, at: eocdOffset + 10))
        guard centralDirectoryOffset >= 0,
              centralDirectoryOffset <= data.count,
              totalEntries <= 10_000 else {
            throw ClosedRequestsImportError.archive("Некорректный central directory.")
        }
        var entries = [String: ZIPEntry]()
        var cursor = centralDirectoryOffset

        var expandedSize: UInt64 = 0
        for _ in 0 ..< totalEntries {
            try Task.checkCancellation()
            guard cursor >= 0, cursor <= data.count - 46 else {
                throw ClosedRequestsImportError.archive("Поврежден central directory.")
            }
            guard readUInt32(from: data, at: cursor) == 0x02014B50 else {
                throw ClosedRequestsImportError.archive("Поврежден central directory.")
            }

            guard readUInt16(from: data, at: cursor + 8) & 1 == 0 else { throw ClosedRequestsImportError.archive("Защищённый паролем XLSX не поддерживается.") }
            let crc = readUInt32(from: data, at: cursor + 16)
            let compressionMethod = Int(readUInt16(from: data, at: cursor + 10))
            let compressedSize = Int(readUInt32(from: data, at: cursor + 20))
            let uncompressedSize = Int(readUInt32(from: data, at: cursor + 24))
            let fileNameLength = Int(readUInt16(from: data, at: cursor + 28))
            let extraFieldLength = Int(readUInt16(from: data, at: cursor + 30))
            let commentLength = Int(readUInt16(from: data, at: cursor + 32))
            let localHeaderOffset = Int(readUInt32(from: data, at: cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + fileNameLength

            guard nameStart >= 0, nameEnd <= data.count else {
                throw ClosedRequestsImportError.archive("Повреждено имя файла в архиве.")
            }
            let nextCursor = nameEnd + extraFieldLength + commentLength
            guard nextCursor >= nameEnd, nextCursor <= data.count else {
                throw ClosedRequestsImportError.archive("Повреждена запись central directory.")
            }

            let nameData = data.subdata(in: nameStart ..< nameEnd)
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ClosedRequestsImportError.archive("Не удалось прочитать имя файла в архиве.")
            }

            guard entries[name] == nil, compressedSize < Int(UInt32.max), uncompressedSize <= 256 * 1024 * 1024 else { throw ClosedRequestsImportError.archive("Неподдерживаемый или слишком большой ZIP.") }
            expandedSize += UInt64(uncompressedSize)
            guard expandedSize <= 512 * 1024 * 1024 else { throw ClosedRequestsImportError.archive("Распакованный XLSX превышает 512 МБ.") }
            entries[name] = ZIPEntry(
                name: name,
                compressedSize: compressedSize,

                uncompressedSize: uncompressedSize,
                compressionMethod: compressionMethod,
                crc: crc, localHeaderOffset: localHeaderOffset
            )

            cursor = nextCursor
        }

        return entries
    }

    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let minimumOffset = max(0, data.count - 65_557)
        var cursor = data.count - 22

        while cursor >= minimumOffset {
            if readUInt32(from: data, at: cursor) == 0x06054B50, cursor + 22 + Int(readUInt16(from: data, at: cursor + 20)) == data.count {
                return cursor
            }
            cursor -= 1
        }

        return nil
    }

    private static func inflate(_ payload: Data, expectedSize: Int) -> Data? {
        guard expectedSize >= 0, expectedSize <= 256 * 1024 * 1024 else { return nil }
        if expectedSize == 0 { return Data() }
        guard !payload.isEmpty else { return nil }
        var destination = Data(count: expectedSize)
        let written = destination.withUnsafeMutableBytes { destinationBuffer in
            payload.withUnsafeBytes { payloadBuffer in
                compression_decode_buffer(
                    destinationBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedSize,
                    payloadBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written == expectedSize else { return nil }
        destination.removeSubrange(written ..< destination.count)
        return destination
    }

    private static func readUInt16(from data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(from data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}
