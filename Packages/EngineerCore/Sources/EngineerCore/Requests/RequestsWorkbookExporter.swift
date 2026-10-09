import Foundation

public enum RequestsWorkbookExporter {
    public static func makeClosedRequestsWorkbook(records: [SimpleOneRequestRecord]) throws -> Data {
        try makeWorkbook(sheetName: "Заявки", rows: closedRequestRows(from: records.map(ClosedRequestProjection.closedRequestRecord(from:))))
    }

    public static func makeTimeReportWorkbook(entries: [TimeReportEntry]) throws -> Data {
        try makeWorkbook(sheetName: "Трудозатраты", rows: timeReportRows(from: entries))
    }

    private static func makeWorkbook(sheetName: String, rows: [[String]]) throws -> Data {
        guard rows.count <= 1_048_576, rows.allSatisfy({ $0.allSatisfy { $0.utf16.count <= 32_767 } }) else { throw WorkbookExportError.excelLimit }
        return try ZIPWriter.makeArchive(entries: [
            ("[Content_Types].xml", contentTypesXML()),
            ("_rels/.rels", rootRelationshipsXML()),
            ("xl/workbook.xml", workbookXML(sheetName: sheetName)),
            ("xl/_rels/workbook.xml.rels", workbookRelationshipsXML()),
            ("xl/worksheets/sheet1.xml", try worksheetXML(rows: rows))
        ])
    }

    private static func closedRequestRows(from records: [ClosedRequestRecord]) -> [[String]] {
        let header = [
            "Номер заявки",
            "Входящий номер",
            "Краткое описание",
            "Статус",
            "Смена инженера",
            "Рабочая группа",
            "Тип заявки",
            "Адрес установки терминала",
            "Заказчик",
            "Контактное лицо",
            "Исполнитель.Имя Фамилия",
            "Модель POS-терминала",
            "ИНН ТСП",
            "Оборудование POS",
            "Серийный номер демонтируемого ТО",
            "Комментарий инженера",
            "Выполнена",
            "Время регистрации",
            "Код закрытия",
            "Решение",
            "ID терминал",
            "Серийный номер установленного ФН",
            "Использованный код активации тарифа ОФД",
            "Использованная SIM карта",
            "Информация"
        ]

        var rows = [header]
        rows.append(contentsOf: records.map { record -> [String] in
            let row: [String] = [
                record.requestNumber,
                record.incomingNumber,
                record.shortDescription,
                record.status,
                record.engineerShift,
                record.workgroup,
                record.requestType,
                record.address,
                record.customer,
                record.contactPerson ?? "",
                record.engineerName,
                record.terminalModel,
                record.merchantTIN ?? "",
                record.posEquipment ?? "",
                record.dismantledEquipmentSerialNumber ?? "",
                record.engineerComment,
                record.closedAt,
                record.registeredAt ?? "",
                record.closureCode ?? "",
                record.resolution ?? "",
                record.terminalID,
                record.installedFiscalStorageSerialNumber ?? "",
                record.ofdTariffActivationCode ?? "",
                record.usedSIMCard ?? "",
                record.rawInfo
            ]
            return row
        })
        return rows
    }

    private static func timeReportRows(from entries: [TimeReportEntry]) -> [[String]] {
        let header = [
            "sys_id",
            "Активность",
            "Период",
            "Когда создано",
            "Дата проведения работ",
            "Время работ (м)",
            "Время в дороге (м)",
            "Внеурочные работы (м)",
            "Внеурочные работы",
            "Рабочие заметки",
            "Трудозатраты нерабочие",
            "Исполнитель"
        ]

        return [header] + entries.map { entry in
            [
                entry.simpleOneRecordID ?? "",
                entry.activity,
                entry.period,
                entry.createdAtRaw,
                entry.workDateRaw ?? entry.createdAtRaw,
                String(entry.workMinutes),
                String(entry.travelMinutes),
                String(entry.overtimeMinutes),
                entry.isOvertime ? "Да" : "Нет",
                entry.notes,
                entry.nonWorkCosts,
                entry.executor
            ]
        }
    }

    private static func worksheetXML(rows: [[String]]) throws -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        """

        for (rowIndex, row) in rows.enumerated() {
            try Task.checkCancellation()
            let excelRow = rowIndex + 1
            xml += #"<row r="\#(excelRow)">"#
            for (columnIndex, value) in row.enumerated() {
                let cellRef = "\(columnName(for: columnIndex + 1))\(excelRow)"
                xml += #"<c r="\#(cellRef)" t="inlineStr"><is><t xml:space="preserve">\#(escapeXML(value))</t></is></c>"#
            }
            xml += "</row>"
        }

        xml += "</sheetData></worksheet>"
        return Data(xml.utf8)
    }

    private static func contentTypesXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """.utf8)
    }

    private static func rootRelationshipsXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """.utf8)
    }

    private static func workbookXML(sheetName: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(escapeXML(sheetName))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """.utf8)
    }

    private static func workbookRelationshipsXML() -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """.utf8)
    }

    private static func columnName(for index: Int) -> String {
        var index = index
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            let scalar = UnicodeScalar(65 + remainder)!
            name.insert(Character(scalar), at: name.startIndex)
            index = (index - 1) / 26
        }
        return name
    }

    private static func escapeXML(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value) || (0x10000...0x10FFFF).contains($0.value) })
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
