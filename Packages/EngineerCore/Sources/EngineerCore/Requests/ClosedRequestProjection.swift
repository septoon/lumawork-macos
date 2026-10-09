import Foundation

struct ClosedRequestRecord: Codable, Hashable, Identifiable, Sendable {
    var id: String {
        requestNumber
    }

    var requestNumber: String
    var shortDescription: String
    var status: String
    var rawStatus: String? = nil
    var engineerShift: String
    var workgroup: String
    var requestType: String
    var address: String
    var customer: String
    var contactPerson: String? = nil
    var contactPhone: String? = nil
    var engineerName: String
    var terminalModel: String
    var merchantTIN: String? = nil
    var posEquipment: String? = nil
    var dismantledEquipmentSerialNumber: String? = nil
    var engineerComment: String
    var closedAt: String
    var deadline: String? = nil
    var completedAt: String? = nil
    var closedInMulticardAt: String? = nil
    var additionalInformation: String? = nil
    var registeredAt: String? = nil
    var closureCode: String? = nil
    var resolution: String? = nil
    var terminalID: String
    var incomingNumber: String
    var infoFields: [ClosedRequestInfoField]
    var rawInfo: String
    var installedFiscalStorageSerialNumber: String? = nil
    var ofdTariffActivationCode: String? = nil
    var usedSIMCard: String? = nil
}

enum ClosedRequestCompletionStatus: String, Sendable {
    case completed
    case refusal

    var title: String {
        switch self {
        case .completed:
            return "Выполнена"
        case .refusal:
            return "Отказ"
        }
    }
}

extension ClosedRequestRecord {
    var completionStatus: ClosedRequestCompletionStatus {
        let normalizedClosureCode = (closureCode ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ru_RU"))

        return normalizedClosureCode.hasPrefix("решено с выездом") ? .completed : .refusal
    }

    var isCompletedWithVisit: Bool {
        completionStatus == .completed
    }
}

enum ClosedRequestProjection {
    static func closedRequestRecord(from record: SimpleOneRequestRecord) -> ClosedRequestRecord {
        let infoFields = simpleOneInfoFields(from: record)
        let merchantTIN = simpleOneInfoValue(for: "ИНН ТСП", in: infoFields)
        let closureCode = simpleOneInfoValue(for: "Код закрытия", in: infoFields)
        let resolution = simpleOneInfoValue(for: "Решение", in: infoFields)
        return ClosedRequestRecord(
            requestNumber: record.number,
            shortDescription: record.shortDescription,
            status: record.state.isEmpty ? "Закрыта" : record.state,
            rawStatus: record.stateRaw,
            engineerShift: simpleOneInfoValue(for: "Смена инженера", in: infoFields),
            workgroup: record.assignmentGroup,
            requestType: record.requestType,
            address: record.address,
            customer: record.customer,
            contactPerson: record.contactPerson.isEmpty ? nil : record.contactPerson,
            contactPhone: record.contactPhone,
            engineerName: record.assignedUser,
            terminalModel: record.terminalModel,
            merchantTIN: merchantTIN.isEmpty ? nil : merchantTIN,
            posEquipment: firstNonEmptySimpleOneValue(simpleOneInfoValue(for: "Оборудование POS", in: infoFields)),
            dismantledEquipmentSerialNumber: firstNonEmptySimpleOneValue(simpleOneInfoValue(for: "Серийный номер демонтируемого ТО", in: infoFields)),
            engineerComment: record.engineerComment,
            closedAt: record.resolvedAt,
            deadline: record.deadline,
            completedAt: record.completedAt,
            closedInMulticardAt: record.closedAt,
            additionalInformation: record.additionalInformation,
            registeredAt: record.registeredAt,
            closureCode: firstNonEmptySimpleOneValue(record.closureCode, closureCode),
            resolution: firstNonEmptySimpleOneValue(record.resolution, resolution),
            terminalID: record.terminalID,
            incomingNumber: record.incomingNumber.isEmpty ? record.number : record.incomingNumber,
            infoFields: infoFields,
            rawInfo: infoFields.map { "\($0.key): \($0.value)" }.joined(separator: "\n"),
            installedFiscalStorageSerialNumber: record.installedFiscalStorageSerialNumber,
            ofdTariffActivationCode: record.ofdTariffActivationCode,
            usedSIMCard: record.usedSIMCard
        )
    }

    private static func simpleOneInfoFields(from record: SimpleOneRequestRecord) -> [ClosedRequestInfoField] {
        let tableInformation = record.tableFields?
            .first { normalizedSimpleOneInfoKey($0.key) == normalizedSimpleOneInfoKey("Информация") }?
            .value ?? ""
        let tableAdditionalInformation = record.tableFields?
            .first { normalizedSimpleOneInfoKey($0.key) == normalizedSimpleOneInfoKey("Доп. информация") }?
            .value ?? ""
        let tableFields = record.tableFields?
            .compactMap { field -> ClosedRequestInfoField? in
                let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !field.key.isEmpty, !value.isEmpty else { return nil }
                return ClosedRequestInfoField(key: field.key, value: value)
            } ?? []
        let parsedFields = parseSimpleOneInfoFields(
            [
                record.additionalInformation ?? "",
                record.description,
                tableInformation,
                tableAdditionalInformation
            ]
        )

        let explicitValues: [(String, String)] = [
            ("Источник", "SimpleOne"),
            ("SimpleOne sys_id", record.sysID),
            ("Номер заявки", record.number),
            ("Краткое описание", record.shortDescription),
            ("Рабочая группа", record.assignmentGroup),
            ("Тип заявки", record.requestType),
            ("Контактное лицо", record.contactPerson),
            ("Модель POS-терминала", record.terminalModel),
            ("Предельный срок СУТС", record.deadline),
            ("Время выполнения", record.completedAt ?? ""),
            ("Время закрытия в МК", record.closedAt ?? ""),
            ("Время регистрации", record.registeredAt ?? ""),
            ("Номер телефона ТСП", record.contactPhone ?? ""),
            ("Комментарий инженера", record.engineerComment),
            ("Код закрытия", record.closureCode ?? ""),
            ("Решение", record.resolution ?? ""),
            ("Доп. информация", record.additionalInformation ?? ""),
            ("Описание", record.description),
            ("Серийный номер установленного ФН", record.installedFiscalStorageSerialNumber ?? ""),
            ("Использованный код активации тарифа ОФД", record.ofdTariffActivationCode ?? ""),
            ("Использованная SIM карта", record.usedSIMCard ?? "")
        ]
        let explicitFields = explicitValues.compactMap { key, value -> ClosedRequestInfoField? in
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return nil }
            return ClosedRequestInfoField(key: key, value: trimmedValue)
        }

        let parsedKeys = Set(parsedFields.map { normalizedSimpleOneInfoKey($0.key) })
        let tableFieldsWithoutParsedDuplicates = tableFields.filter { !parsedKeys.contains(normalizedSimpleOneInfoKey($0.key)) }
        let parsedAndTableKeys = parsedKeys.union(tableFieldsWithoutParsedDuplicates.map { normalizedSimpleOneInfoKey($0.key) })
        let explicitFieldsWithoutDuplicates = explicitFields.filter { !parsedAndTableKeys.contains(normalizedSimpleOneInfoKey($0.key)) }
        return parsedFields + tableFieldsWithoutParsedDuplicates + explicitFieldsWithoutDuplicates
    }

    private static func simpleOneInfoValue(
        for key: String,
        in fields: [ClosedRequestInfoField]
    ) -> String {
        let normalizedKey = normalizedSimpleOneInfoKey(key)
        return fields
            .first { normalizedSimpleOneInfoKey($0.key) == normalizedKey }?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func firstNonEmptySimpleOneValue(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func parseSimpleOneInfoFields(_ texts: [String]) -> [ClosedRequestInfoField] {
        texts.flatMap { text in
            text
                .split(whereSeparator: \.isNewline)
                .compactMap { rawLine -> ClosedRequestInfoField? in
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty else { return nil }

                    guard let separator = line.firstIndex(of: ":") else {
                        return ClosedRequestInfoField(key: line, value: "")
                    }

                    let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return nil }
                    return ClosedRequestInfoField(key: key, value: value)
                }
        }
    }

    private static func normalizedSimpleOneInfoKey(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

}
