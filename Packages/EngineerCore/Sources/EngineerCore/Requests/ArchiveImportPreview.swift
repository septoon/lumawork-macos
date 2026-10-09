import Foundation

public struct ArchiveImportPreview: Sendable, Identifiable {
    public let id = UUID()
    public let fileName: String
    public let records: [SimpleOneRequestRecord]
    public let duplicateCount: Int
    public static func parse(data: Data, fileName: String) throws -> Self {
        let parsed = try XLSXRequestsParser.parse(data: data)
        var byNumber: [String: SimpleOneRequestRecord] = [:]
        for record in parsed { try Task.checkCancellation(); byNumber[record.requestNumber] = record.simpleOneRecord }
        return Self(fileName: fileName, records: byNumber.values.sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }, duplicateCount: parsed.count - byNumber.count)
    }
}

extension ClosedRequestRecord {
    var simpleOneRecord: SimpleOneRequestRecord {
        let fields = infoFields + [ClosedRequestInfoField(key: "Информация", value: rawInfo),
                                  ClosedRequestInfoField(key: "ИНН ТСП", value: merchantTIN ?? ""),
                                  ClosedRequestInfoField(key: "Оборудование POS", value: posEquipment ?? ""),
                                  ClosedRequestInfoField(key: "Серийный номер демонтируемого ТО", value: dismantledEquipmentSerialNumber ?? ""),
                                  ClosedRequestInfoField(key: "Смена инженера", value: engineerShift)]
        let id = infoFields.first { $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "simpleone sys_id" }?.value ?? ""
        let sysID = id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? id : ""
        return SimpleOneRequestRecord(source: .closed, sysID: sysID, number: requestNumber, incomingNumber: incomingNumber,
                                      registeredAt: registeredAt, state: status, stateRaw: rawStatus, shortDescription: shortDescription,
                                      assignmentGroup: workgroup, requestType: requestType, address: address, customer: customer,
                                      deadline: deadline ?? "", resolvedAt: closedAt, completedAt: completedAt, closedAt: closedInMulticardAt,
                                      assignedUser: engineerName, terminalModel: terminalModel, terminalID: terminalID,
                                      contactPerson: contactPerson ?? "", contactPhone: contactPhone, engineerComment: engineerComment,
                                      closureCode: closureCode, resolution: resolution, additionalInformation: additionalInformation,
                                      description: rawInfo, installedFiscalStorageSerialNumber: installedFiscalStorageSerialNumber,
                                      ofdTariffActivationCode: ofdTariffActivationCode, usedSIMCard: usedSIMCard, tableFields: fields)
    }
}
