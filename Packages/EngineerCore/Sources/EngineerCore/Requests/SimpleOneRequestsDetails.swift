import Foundation

extension SimpleOneRequestsService {
    func fetchRequest(
        sysID: String,
        fallback: SimpleOneRequestRecord,
        authKey: String
    ) async throws -> SimpleOneRequestRecord {
        let response = try await request(path: "/record/itsm_request/\(sysID)", authKey: authKey)
        guard let item = recordItem(from: response) else {
            throw SimpleOneServiceError.invalidResponse
        }
        let detailItem = flattenedRecordItem(from: item)
        let detailAssignedUserName = fieldDisplayString(
            detailItem,
            "assigned_user.c_full_name",
            "assigned_user",
            "Исполнитель",
            "Исполнитель.Имя Фамилия"
        )
        let detailAssignedUserID = fieldString(
            detailItem,
            "assigned_user.value",
            "assigned_user.database_value",
            "assigned_user.sys_id",
            "assigned_user"
        )
        var record = makeRequestRecord(
            from: mergedRecordItem(listItem: fallback, detailItem: detailItem),
            source: fallback.source
        )

        let resolvedDetailName = detailAssignedUserName.isEmpty ? record.assignedUser : detailAssignedUserName
        let normalizedDetailName = normalizedAssignedUser(resolvedDetailName)
        let normalizedDetailID = normalizedAssignedUser(detailAssignedUserID)
        let trimmedDetailID = detailAssignedUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailHasDistinctID = !normalizedDetailID.isEmpty
            && (normalizedDetailID != normalizedDetailName
                || (trimmedDetailID.count == 18 && trimmedDetailID.allSatisfy(\.isNumber)))
        if detailHasDistinctID {
            record.assignedUserID = detailAssignedUserID
        } else if normalizedDetailName.isEmpty || normalizedDetailName == normalizedAssignedUser(fallback.assignedUser) {
            record.assignedUserID = fallback.assignedUserID
        } else {
            record.assignedUserID = nil
        }
        return record
    }

    func flattenedRecordItem(from item: [String: Any]) -> [String: Any] {
        guard let sections = item["sections"] as? [[String: Any]] else {
            return item
        }

        var flattened = item
        for section in sections {
            guard let elements = section["elements"] as? [[String: Any]] else { continue }
            for element in elements {
                guard let value = element["value"] else { continue }

                for keyName in ["sys_column_name", "system_name", "name"] {
                    guard let key = element[keyName] as? String, !key.isEmpty else { continue }
                    if fieldString(flattened, key).isEmpty {
                        setFieldValue(value, for: key, in: &flattened)
                    }
                }
            }
        }
        return flattened
    }

    func recordItem(from response: [String: Any]) -> [String: Any]? {
        if let data = response["data"] as? [String: Any] {
            if let item = data["item"] as? [String: Any] {
                return item
            }
            if let record = data["record"] as? [String: Any] {
                return record
            }
            if let fields = data["fields"] as? [String: Any] {
                return fields
            }
            return data
        }
        if let item = response["item"] as? [String: Any] {
            return item
        }
        if let record = response["record"] as? [String: Any] {
            return record
        }
        return nil
    }

    func mergedRecordItem(
        listItem fallback: SimpleOneRequestRecord,
        detailItem: [String: Any]
    ) -> [String: Any] {
        var item = detailItem
        let fallbackMulticardStatus = fallback.tableFields?
            .first { $0.key.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == "мк статус" }?
            .value ?? ""
        let fallbackDismantledPOSSerialNumber = fallback.tableFields?
            .first { normalizedInfoKey($0.key) == normalizedInfoKey("Серийный номер демонтируемого ТО") }?
            .value ?? ""
        let fallbackPOSSerialNumber = fallback.tableFields?
            .first { normalizedInfoKey($0.key) == normalizedInfoKey("Оборудование POS") }?
            .value ?? ""
        let fallbacks: [(String, String)] = [
            ("sys_id", fallback.sysID),
            ("number", fallback.number),
            ("incoming_number", fallback.incomingNumber),
            ("registered_at", fallback.registeredAt ?? ""),
            ("state", fallback.state),
            ("multicard_state", fallbackMulticardStatus),
            ("short_description", fallback.shortDescription),
            ("assignment_group", fallback.assignmentGroup),
            ("client_service_id.parent", fallback.clientServiceParent ?? ""),
            ("client_service_id", fallback.clientService ?? ""),
            ("multicard_request_type", fallback.requestType),
            ("multicard_terminal_address", fallback.address),
            ("multicard_name_client", fallback.customer),
            ("multicard_deadline", fallback.deadline),
            ("resolved_at", fallback.resolvedAt),
            ("completed_at", fallback.completedAt ?? ""),
            ("closed_at", fallback.closedAt ?? ""),
            ("assigned_user", fallback.assignedUser),
            ("assigned_user.c_full_name", fallback.assignedUser),
            ("sys_updated_at", fallback.sysUpdatedAt ?? ""),
            ("multicard_terminal_model", fallback.terminalModel),
            ("multicard_id_terminal", fallback.terminalID),
            ("multicard_pos", fallbackPOSSerialNumber),
            ("pb_sn_pos_uninstall", fallbackDismantledPOSSerialNumber),
            ("multicard_contact_person", fallback.contactPerson),
            ("multicard_contact_phone", fallback.contactPhone ?? ""),
            ("multicard_comment_ing", fallback.engineerComment),
            ("multicard_information", fallback.additionalInformation ?? ""),
            ("description", fallback.description)
        ]

        for (key, value) in fallbacks where fieldString(item, key).isEmpty && !value.isEmpty {
            setFieldValue(value, for: key, in: &item)
        }
        return item
    }

    private func normalizedAssignedUser(_ raw: String) -> String { raw.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}
