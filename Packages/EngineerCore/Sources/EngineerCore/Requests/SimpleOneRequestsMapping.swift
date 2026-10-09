import Foundation

extension SimpleOneRequestsService {
    func makeRequestRecord(from item: [String: Any], source: SimpleOneRequestSource) -> SimpleOneRequestRecord {
        let information = fieldString(
            item,
            "multicard_information",
            "multicard_info",
            "information",
            "Информация"
        )
        let systemAdditionalInformation = fieldString(
            item,
            "multicard_additional_information",
            "additional_information"
        )
        let additionalInformation = fieldString(
            item,
            "Доп. информация",
            "Дополнительная информация"
        )
        let description = fieldString(item, "description", "Описание")
        let infoTexts = [
            information,
            systemAdditionalInformation,
            additionalInformation,
            description
        ]
        let infoFields = parseSimpleOneInfoFields(infoTexts)
        let sbpID = firstNonEmpty(
            fieldString(item, "multicard_sbp_id", "multicard_id_sbp", "sbp_id", "id_sbp", "ID СБП"),
            infoValue(for: ["ID СБП"], in: infoFields),
            labeledTextValue(for: ["ID СБП"], in: infoTexts)
        )
        let merchantTIN = firstNonEmpty(
            fieldString(item, "multicard_merchant_tin", "multicard_tsp_inn", "merchant_tin", "inn_tsp", "ИНН ТСП"),
            infoValue(for: ["ИНН ТСП"], in: infoFields),
            labeledTextValue(for: ["ИНН ТСП"], in: infoTexts)
        )
        let closureCode = firstNonEmpty(
            fieldDisplayString(
                item,
                "new_closure_code",
                "close_code",
                "closure_code",
                "resolution_code",
                "multicard_close_code",
                "multicard_closure_code",
                "Код закрытия"
            ),
            infoValue(for: ["Код закрытия"], in: infoFields),
            labeledTextValue(for: ["Код закрытия"], in: infoTexts)
        )
        let resolution = firstNonEmpty(
            fieldString(
                item,
                "closure_notes",
                "close_notes",
                "resolution",
                "solution",
                "resolved_notes",
                "multicard_resolution",
                "multicard_solution",
                "Решение"
            ),
            infoValue(for: ["Решение"], in: infoFields),
            labeledTextValue(for: ["Решение"], in: infoTexts)
        )
        let incomingNumber = firstNonEmpty(
            fieldString(
                item,
                "incoming_number",
                "multicard_incoming_number",
                "multicard_request_number",
                "multicard_number",
                "multicard_suts_number",
                "u_incoming_number",
                "Входящий номер",
                "Номер заявки Мультикарты"
            ),
            infoValue(for: ["Входящий номер", "Номер заявки Мультикарты", "Номер заявки Мультикарта", "Номер заявки"], in: infoFields),
            labeledTextValue(for: ["Входящий номер", "Номер заявки Мультикарты", "Номер заявки Мультикарта", "Номер заявки"], in: infoTexts),
            fieldString(item, "short_description").hasPrefix("SUTS") ? fieldString(item, "short_description") : ""
        )
        let tableFields = simpleOneTableFields(
            from: item,
            incomingNumber: incomingNumber,
            information: information,
            additionalInformation: resolvedSimpleOneAdditionalInformation(
                systemValue: systemAdditionalInformation,
                localizedValue: additionalInformation
            ),
            sbpID: sbpID,
            merchantTIN: merchantTIN,
            closureCode: closureCode,
            resolution: resolution,
            infoFields: infoFields
        )

        return SimpleOneRequestRecord(
            source: source,
            sysID: stringValue(item["sys_id"]),
            number: fieldString(item, "number", "__display_value"),
            incomingNumber: incomingNumber,
            registeredAt: fieldString(
                item,
                "registered_at",
                "opened_at",
                "sys_created_at",
                "created_at",
                "Время регистрации"
            ),
            waitingReason: fieldDisplayString(
                item,
                "waiting_reason",
                "hold_reason",
                "pending_reason",
                "multicard_waiting_reason",
                "Причина ожидания"
            ),
            state: fieldDisplayString(item, "state"),
            stateRaw: fieldString(item, "state"),
            shortDescription: fieldString(item, "short_description"),
            assignmentGroup: fieldDisplayString(item, "assignment_group"),
            initiator: fieldString(
                item,
                "initiator.c_full_name",
                "opened_by.c_full_name",
                "caller_id.c_full_name",
                "Инициатор.Имя Фамилия"
            ),
            priority: fieldDisplayString(item, "priority", "Приоритет"),
            clientServiceParent: fieldDisplayString(
                item,
                "client_service_id.parent",
                "client_service.parent",
                "client_service_parent",
                "parent_client_service",
                "Клиентский сервис (Родитель)"
            ),
            clientService: fieldDisplayString(
                item,
                "client_service_id",
                "client_service",
                "Клиентский сервис"
            ),
            requestType: fieldString(
                item,
                "multicard_request_type",
                "request_type",
                "itsm_request_type",
                "service_request_type",
                "multicard_type",
                "multicard_type_request",
                "multicard_work_type",
                "type",
                "Тип заявки"
            ),
            address: firstNonEmpty(
                fieldString(item, "multicard_terminal_address", "Адрес установки терминала"),
                infoValue(for: ["Адрес установки терминала", "Адрес ТСП", "Адрес"], in: infoFields)
            ),
            customer: firstNonEmpty(
                fieldString(item, "multicard_name_client", "Заказчик"),
                infoValue(for: ["Заказчик", "Наименование юр.лица", "Наименование юр. лица", "Клиент"], in: infoFields)
            ),
            deadline: fieldString(item, "multicard_deadline", "Предельный срок СУТС", "Предельный срок"),
            resolvedAt: fieldString(
                item,
                "completed_at",
                "completion_time",
                "multicard_completed_at",
                "Выполнена",
                "Время Выполнена",
                "Время \"Выполнена\"",
                "multicard_closing_date",
                "resolved_at",
                "Дата закрытия в МК",
                "Дата закрытия"
            ),
            completedAt: fieldString(
                item,
                "completed_at",
                "completion_time",
                "multicard_completed_at",
                "Выполнена",
                "Время Выполнена",
                "Время \"Выполнена\""
            ),
            closedAt: fieldString(
                item,
                "closed_at",
                "multicard_closing_date",
                "resolved_at",
                "Дата закрытия в МК",
                "Дата закрытия"
            ),
            assignedUser: fieldDisplayString(
                item,
                "assigned_user.c_full_name",
                "assigned_user",
                "Исполнитель",
                "Исполнитель.Имя Фамилия"
            ),
            assignedUserID: fieldString(
                item,
                "assigned_user.value",
                "assigned_user.database_value",
                "assigned_user.sys_id",
                "assigned_user"
            ),
            sysUpdatedAt: fieldString(item, "sys_updated_at", "Обновлено"),
            terminalModel: firstNonEmpty(
                fieldString(item, "multicard_terminal_model", "Модель POS-терминала"),
                infoValue(for: ["Модель POS-терминала", "Модель POS", "Модель терминала", "Модель устанавливаемого ТО"], in: infoFields)
            ),
            terminalID: firstNonEmpty(
                fieldString(item, "multicard_id_terminal", "ID терминал", "ID терминала"),
                infoValue(for: ["ID терминал", "ID терминала", "ID терминал", "Оборудование POS"], in: infoFields)
            ),
            contactPerson: fieldString(item, "multicard_contact_person", "Контактное лицо", "Kонтактное лицо"),
            contactPhone: firstNonEmpty(
                fieldString(
                    item,
                    "multicard_contact_phone",
                    "multicard_phone",
                    "contact_phone",
                    "phone",
                    "Номер телефона ТСП",
                    "Телефон ТСП"
                ),
                infoValue(for: ["Номер телефона ТСП", "Телефон ТСП", "Телефон"], in: infoFields)
            ),
            engineerComment: fieldString(item, "multicard_comment_ing"),
            closureCode: closureCode.isEmpty ? nil : closureCode,
            resolution: resolution.isEmpty ? nil : resolution,
            additionalInformation: firstNonEmpty(
                information,
                systemAdditionalInformation,
                additionalInformation
            ),
            description: description,
            installedFiscalStorageSerialNumber: fieldString(
                item,
                "multicard_installed_fn_serial_number",
                "multicard_fiscal_storage_serial_number",
                "multicard_serial_number_installed_fn",
                "multicard_fn_serial_number",
                "Серийный номер установленного ФН",
                "Cерийный номер установленного ФН"
            ),
            ofdTariffActivationCode: fieldString(
                item,
                "multicard_ofd_tariff_activation_code",
                "multicard_used_ofd_tariff_activation_code",
                "multicard_activation_code_ofd",
                "multicard_ofd_activation_code",
                "Использованный код активации тарифа ОФД"
            ),
            usedSIMCard: fieldString(
                item,
                "multicard_used_sim_card",
                "multicard_sim_card",
                "multicard_used_sim",
                "multicard_sim",
                "Использованная SIM карта"
            ),
            tableFields: tableFields
        )
    }

    func simpleOneTableFields(
        from item: [String: Any],
        incomingNumber: String,
        information: String,
        additionalInformation: String,
        sbpID: String,
        merchantTIN: String,
        closureCode: String,
        resolution: String,
        infoFields: [ClosedRequestInfoField]
    ) -> [ClosedRequestInfoField] {
        [
            ("Номер заявки", fieldString(item, "number", "__display_value", "Номер заявки")),
            ("Входящий номер", incomingNumber),
            ("Краткое описание", fieldString(item, "short_description", "Краткое описание")),
            ("Статус", fieldDisplayString(item, "state", "Статус")),
            ("Код статуса", fieldString(item, "state")),
            ("Рабочая группа", fieldDisplayString(item, "assignment_group", "Рабочая группа")),
            ("Приоритет", fieldDisplayString(item, "priority", "Приоритет")),
            ("Причина ожидания", fieldDisplayString(item, "waiting_reason", "hold_reason", "pending_reason", "multicard_waiting_reason", "Причина ожидания")),
            ("Тип заявки", firstNonEmpty(fieldString(item, "multicard_request_type", "request_type", "Тип заявки"), infoValue(for: ["Тип заявки"], in: infoFields))),
            ("Адрес установки терминала", firstNonEmpty(fieldString(item, "multicard_terminal_address", "Адрес установки терминала"), infoValue(for: ["Адрес установки терминала", "Адрес ТСП", "Адрес"], in: infoFields))),
            ("Заказчик", firstNonEmpty(fieldString(item, "multicard_name_client", "Заказчик"), infoValue(for: ["Заказчик", "Наименование юр.лица", "Наименование юр. лица", "Клиент"], in: infoFields))),
            ("Номер телефона ТСП", firstNonEmpty(fieldString(item, "multicard_phone_tsp", "multicard_tsp_phone", "multicard_terminal_phone", "multicard_contact_phone", "multicard_phone_client", "multicard_merchant_phone", "Номер телефона ТСП", "Телефон ТСП"), infoValue(for: ["Номер телефона ТСП", "Телефон ТСП"], in: infoFields))),
            ("ID СБП", sbpID),
            ("ИНН ТСП", merchantTIN),
            ("Модель POS-терминала", firstNonEmpty(fieldString(item, "multicard_terminal_model", "Модель POS-терминала"), infoValue(for: ["Модель POS-терминала", "Модель POS", "Модель терминала", "Модель устанавливаемого ТО"], in: infoFields))),
            ("Информация", information),
            ("ID терминал", firstNonEmpty(fieldString(item, "multicard_id_terminal", "ID терминал", "ID терминала"), infoValue(for: ["ID терминал", "ID терминала", "Оборудование POS"], in: infoFields))),
            ("Комментарий инженера", fieldString(item, "multicard_comment_ing", "Комментарий инженера")),
            ("Доп. информация", firstNonEmpty(additionalInformation, infoValue(for: ["Доп. информация", "Доп информация", "Дополнительная информация"], in: infoFields))),
            ("Исполнитель", fieldString(item, "assigned_user.c_full_name", "Исполнитель", "Исполнитель.Имя Фамилия")),
            ("Код закрытия", closureCode),
            ("Решение", resolution),
            ("Kонтактное лицо", fieldString(item, "multicard_contact_person", "Контактное лицо", "Kонтактное лицо")),
            ("Предельный срок СУТС", fieldString(item, "multicard_deadline", "Предельный срок СУТС", "Предельный срок")),
            ("Время выполнения", fieldString(item, "completed_at", "completion_time", "multicard_completed_at", "Выполнена", "Время Выполнена", "Время \"Выполнена\"")),
            ("Дата закрытия в МК", fieldString(item, "closed_at", "multicard_closing_date", "resolved_at", "Дата закрытия в МК", "Дата закрытия")),
            ("Оборудование POS", firstNonEmpty(fieldString(item, "multicard_pos", "Оборудование POS"), infoValue(for: ["Оборудование POS"], in: infoFields))),
            ("Терминал вендора POS", fieldString(item, "multicard_terminal_vendor_pos", "Терминал вендора POS")),
            ("Номер принятого оборудования POS", fieldString(item, "multicard_return_number_pos", "Номер принятого оборудования POS")),
            ("Оборудование Pin Pad", firstNonEmpty(fieldString(item, "multicard_pin_pad", "Оборудование Pin Pad"), infoValue(for: ["Оборудование Pin Pad"], in: infoFields))),
            ("Терминал вендора PIN", fieldString(item, "multicard_terminal_vendor_pin", "Терминал вендора PIN")),
            ("Модель PIN-Pad", fieldString(item, "multicard_pin_pad_model", "Модель PIN-Pad")),
            ("Номер принятого оборудования PIN", fieldString(item, "multicard_return_number_pin", "Номер принятого оборудования PIN")),
            ("Серийный номер демонтируемого ТО", firstNonEmpty(
                fieldString(item, "pb_sn_pos_uninstall", "Серийный номер демонтируемого ТО"),
                infoValue(for: ["Серийный номер демонтируемого ТО"], in: infoFields)
            )),
            ("Серийный номер демонтируемого PIN", infoValue(for: ["Серийный номер демонтируемого PIN"], in: infoFields)),
            ("Производитель устанавливаемого ТО", infoValue(for: ["Производитель устанавливаемого ТО"], in: infoFields)),
            ("Модель устанавливаемого ТО", infoValue(for: ["Модель устанавливаемого ТО"], in: infoFields)),
            ("Тип устанавливаемого ТО", infoValue(for: ["Тип устанавливаемого ТО"], in: infoFields)),
            ("Принадлежность оборудования по заявке", infoValue(for: ["Принадлежность оборудования по заявке"], in: infoFields)),
            ("Время создания в МК", fieldString(item, "multicard_created_at", "Время создания в МК")),
            ("МК Статус", multicardStatusDisplayString(item, infoFields: infoFields)),
            ("Статус заявки Мультикарта", localizedMulticardStatus(fieldString(item, "multicard_request_state", "Статус заявки Мультикарта"))),
            ("МК Сотрудник склада", fieldDisplayString(item, "multicard_store_empl", "МК Сотрудник склада")),
            ("Город склада", firstNonEmpty(fieldString(item, "multicard_city", "Город склада"), infoValue(for: ["Город склада"], in: infoFields)))
        ]
        .map { key, value in
            ClosedRequestInfoField(key: key, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func multicardStatusDisplayString(
        _ item: [String: Any],
        infoFields: [ClosedRequestInfoField]
    ) -> String {
        let fieldValue = Self.multicardStatusColumns
            .map { fieldDisplayString(item, $0) }
            .map(localizedMulticardStatus)
            .first { !$0.isEmpty } ?? ""
        return firstNonEmpty(
            fieldValue,
            localizedMulticardStatus(infoValue(for: ["МК Статус", "МК статус"], in: infoFields))
        )
    }

    func parseSimpleOneInfoFields(_ texts: [String]) -> [ClosedRequestInfoField] {
        texts
            .flatMap { text in
                normalizedMultilineInfoText(text)
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

    func allTextValues(from raw: Any) -> [String] {
        if raw is NSNull {
            return []
        }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let number = raw as? NSNumber {
            return [number.stringValue]
        }
        if let dictionary = raw as? [String: Any] {
            return dictionary.flatMap { key, value -> [String] in
                var values: [String] = []
                let resolved = fieldValueString(value)
                if !resolved.isEmpty {
                    values.append("\(key): \(resolved)")
                }
                values.append(contentsOf: allTextValues(from: value))
                return values
            }
        }
        if let array = raw as? [Any] {
            return array.flatMap { allTextValues(from: $0) }
        }
        let fallback = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? [] : [fallback]
    }

    func labeledTextValue(for labels: [String], in texts: [String]) -> String {
        for text in texts {
            let normalizedText = normalizedMultilineInfoText(text)
            for label in labels {
                if let value = labeledTextValue(for: label, in: normalizedText) {
                    return value
                }
            }
        }
        return ""
    }

    func labeledTextValue(for label: String, in text: String) -> String? {
        let marker = "\(label):"
        guard let markerRange = text.range(of: marker, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }

        let suffix = String(text[markerRange.upperBound...])
        let endIndex = earliestKnownLabelIndex(in: suffix)
        let rawValue: String
        if let endIndex {
            rawValue = String(suffix[..<endIndex])
        } else {
            rawValue = suffix
        }

        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, normalizedInfoKey(value) != "информация отсутствует" else {
            return nil
        }
        return value
    }

    func earliestKnownLabelIndex(in text: String) -> String.Index? {
        simpleOneKnownInfoLabels
            .compactMap { label -> String.Index? in
                text.range(
                    of: "(?:^|\\n|\\s)\(NSRegularExpression.escapedPattern(for: label))\\s*:",
                    options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
                )?.lowerBound
            }
            .min()
    }

    func normalizedMultilineInfoText(_ raw: String) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "&#xA;", with: "\n")
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "</(div|p|li|tr)>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression, .caseInsensitive])
        return simpleOneKnownInfoLabels.reduce(normalized) { result, label in
            result.replacingOccurrences(
                of: "([^\\n])\\s*(\(NSRegularExpression.escapedPattern(for: label))\\s*:)",
                with: "$1\n$2",
                options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]
            )
        }
    }

    func infoValue(for keys: [String], in fields: [ClosedRequestInfoField]) -> String {
        for key in keys {
            let normalizedKey = normalizedInfoKey(key)
            if let value = fields.first(where: { normalizedInfoKey($0.key) == normalizedKey })?.value.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty,
               normalizedInfoKey(value) != "информация отсутствует" {
                return value
            }
        }
        return ""
    }

    func normalizedInfoKey(_ raw: String) -> String {
        raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    func serverError(from response: [String: Any]) -> SimpleOneServiceError? {
        if let status = response["status"] as? String, status == "OK" {
            return nil
        }
        if let errors = response["errors"] as? [[String: Any]],
           let message = errors.compactMap({ $0["message"] as? String }).first(where: { !$0.isEmpty }) {
            if message.localizedCaseInsensitiveContains("credentials") {
                return .unauthorized
            }
            return .server(message)
        }
        if let message = response["message"] as? String, !message.isEmpty {
            return .server(message)
        }
        if let error = response["error"] as? String, !error.isEmpty {
            return .server(error)
        }
        return nil
    }
}

private let simpleOneKnownInfoLabels = [
    "Номер заявки Мультикарты",
    "Принадлежность оборудования по заявке",
    "Серийный номер демонтируемого ТО",
    "Серийный номер демонтируемого PIN",
    "Производитель устанавливаемого ТО",
    "Модель устанавливаемого ТО",
    "Модель POS-терминала",
    "Модель POS",
    "Модель терминала",
    "Тип устанавливаемого ТО",
    "Согласованная дата и время проведения работ",
    "Согласованная дата и время предоставления доступа",
    "Тип заявки",
    "Категория обслуживания",
    "Город склада",
    "Адрес установки терминала",
    "Адрес ТСП",
    "Заказчик",
    "Оборудование POS",
    "Оборудование Pin Pad",
    "Доп. информация",
    "Доп информация",
    "Дополнительная информация",
    "ID СБП",
    "ИНН ТСП",
    "Код закрытия",
    "Решение",
    "Комментарий к результату выезда",
    "Комментарий инженера"
]

func fieldDisplayString(_ item: [String: Any], _ keys: String...) -> String {
    for key in keys {
        if let value = fieldRawValue(item, key) {
            let resolved = fieldValueString(value, preferDisplay: true)
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    return ""
}

func fieldString(_ item: [String: Any], _ keys: String...) -> String {
    for key in keys {
        if let value = fieldRawValue(item, key) {
            let resolved = fieldValueString(value)
            if !resolved.isEmpty {
                return resolved
            }
        }
    }
    return ""
}

func firstNonEmpty(_ values: String...) -> String {
    values
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? ""
}

func localizedMulticardStatus(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: " ", with: "")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    switch normalized {
    case "storeequipissued":
        return "Оборудование выдано"
    default:
        return trimmed
    }
}

func fieldRawValue(_ item: [String: Any], _ key: String) -> Any? {
    if let value = item[key] {
        return value
    }

    let parts = key.split(separator: ".").map(String.init)
    guard parts.count > 1 else {
        return nil
    }

    var current: Any? = item
    for part in parts {
        guard let dictionary = current as? [String: Any] else {
            return nil
        }
        current = dictionary[part]
    }
    return current
}

func setFieldValue(_ value: Any, for key: String, in item: inout [String: Any]) {
    let parts = key.split(separator: ".").map(String.init)
    guard !parts.isEmpty else {
        return
    }
    setFieldValue(value, parts: parts, in: &item)
}

func setFieldValue(_ value: Any, parts: [String], in item: inout [String: Any]) {
    guard let first = parts.first else {
        return
    }
    guard parts.count > 1 else {
        item[first] = value
        return
    }

    var nested = item[first] as? [String: Any] ?? [:]
    setFieldValue(value, parts: Array(parts.dropFirst()), in: &nested)
    item[first] = nested
}

func fieldValueString(_ raw: Any, preferDisplay: Bool = false) -> String {
    if raw is NSNull {
        return ""
    }
    if let string = raw as? String {
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let number = raw as? NSNumber {
        return number.stringValue
    }
    if let dictionary = raw as? [String: Any] {
        if preferDisplay {
            let display = stringValue(dictionary["display_value"])
            if !display.isEmpty {
                return display
            }
        }
        if let value = dictionary["value"] {
            return fieldValueString(value, preferDisplay: preferDisplay)
        }
        let display = stringValue(dictionary["display_value"])
        if !display.isEmpty {
            return display
        }
        return stringValue(dictionary["database_value"])
    }
    if let array = raw as? [Any] {
        return array
            .map { fieldValueString($0, preferDisplay: true) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
    return String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
}


func resolvedSimpleOneAdditionalInformation(
    systemValue: String,
    localizedValue: String
) -> String {
    let systemValue = systemValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !systemValue.isEmpty {
        return systemValue
    }
    return localizedValue.trimmingCharacters(in: .whitespacesAndNewlines)
}
