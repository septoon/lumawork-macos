import Foundation

enum ZIPWriter {
    static func makeArchive(entries: [(path: String, data: Data)]) throws -> Data {
        guard entries.count <= Int(UInt16.max), entries.allSatisfy({ $0.path.utf8.count <= Int(UInt16.max) && $0.data.count < Int(UInt32.max) }), entries.reduce(UInt64(0), { $0 + UInt64($1.data.count) + UInt64($1.path.utf8.count) * 2 + 128 }) < UInt64(UInt32.max) else { throw WorkbookExportError.zipLimit }
        var archive = Data()
        var centralDirectory = Data()

        for entry in entries {
            try Task.checkCancellation()
            let localHeaderOffset = UInt32(archive.count)
            let nameData = Data(entry.path.utf8)
            let crc = try crc32(entry.data)
            let size = UInt32(entry.data.count)

            appendUInt32(0x04034B50, to: &archive)
            appendUInt16(20, to: &archive)
            appendUInt16(0x0800, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt16(0, to: &archive)
            appendUInt32(crc, to: &archive)
            appendUInt32(size, to: &archive)
            appendUInt32(size, to: &archive)
            appendUInt16(UInt16(nameData.count), to: &archive)
            appendUInt16(0, to: &archive)
            archive.append(nameData)
            archive.append(entry.data)

            appendUInt32(0x02014B50, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(20, to: &centralDirectory)
            appendUInt16(0x0800, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(crc, to: &centralDirectory)
            appendUInt32(size, to: &centralDirectory)
            appendUInt32(size, to: &centralDirectory)
            appendUInt16(UInt16(nameData.count), to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt16(0, to: &centralDirectory)
            appendUInt32(0, to: &centralDirectory)
            appendUInt32(localHeaderOffset, to: &centralDirectory)
            centralDirectory.append(nameData)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        appendUInt32(0x06054B50, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt16(UInt16(entries.count), to: &archive)
        appendUInt32(UInt32(centralDirectory.count), to: &archive)
        appendUInt32(centralDirectoryOffset, to: &archive)
        appendUInt16(0, to: &archive)

        return archive
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
    private static func crc32(_ data: Data) throws -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for (index, byte) in data.enumerated() {
            if index & 4095 == 0 { try Task.checkCancellation() }
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ 0xffffffff
    }
}

enum WorkbookExportError: LocalizedError {
    case excelLimit, zipLimit
    var errorDescription: String? {
        switch self {
        case .excelLimit: "Данные превышают ограничения Excel: 1 048 576 строк или 32 767 символов в ячейке."
        case .zipLimit: "Данные превышают допустимый размер XLSX-файла."
        }
    }
}
