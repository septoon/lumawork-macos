import Foundation

@MainActor public final class AssistantLocalToolExecutor {
    private let requests: RequestsRepository
    private let backpack: SimpleOneResourceRepository<[BackpackItem]>
    private let loadBackpack: () async throws -> Void
    private let context: () -> SessionContext?
    public init(requests: RequestsRepository, backpack: SimpleOneResourceRepository<[BackpackItem]>, context: @escaping () -> SessionContext?, loadBackpack: @escaping () async throws -> Void) {
        self.requests = requests; self.backpack = backpack; self.context = context; self.loadBackpack = loadBackpack
    }
    private func check(_ expected: SessionContext) throws { try Task.checkCancellation(); guard context() == expected else { throw CancellationError() } }
    public func execute(_ calls: [AssistantAPIToolRequest], expectedContext: SessionContext) async throws -> [AssistantAPIToolResult] {
        var results: [AssistantAPIToolResult] = []
        for call in calls.prefix(4) {
            try check(expectedContext)
            let payload: AssistantJSONValue
            switch call.name {
            case "active_requests", "closed_requests":
                let source: SimpleOneRequestSource = call.name == "active_requests" ? .active : .closed
                try await requests.load(source); try check(expectedContext)
                let all = requests.records(source), selected = selectedRecords(all, arguments: call.arguments, limit: call.arguments.limit)
                payload = .object(["count": .number(Double(all.count)), "updatedAt": requests.updatedAt(source).map { .string(Self.dateString($0)) } ?? .null, "requests": .array(selected.map { requestSummary($0, closed: source == .closed) })])
            case "request_details":
                try await requests.load(.active); try check(expectedContext)
                let id = call.arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var all = requests.records(.active)
                if !all.contains(where: { Self.matchesIdentifier($0, id: id) }) { try await requests.load(.closed); try check(expectedContext); all += requests.records(.closed) }
                if let record = Self.findRecord(all, id: id, query: call.arguments["query"]?.stringValue) { let value = try await requests.detail(record); try check(expectedContext); payload = requestDetails(value) }
                else { payload = .object(["status": .string("not_found")]) }
            case "backpack":
                try await loadBackpack(); try check(expectedContext)
                let all = backpack.value("all") ?? [], selected = Self.filteredBackpackItems(all, query: call.arguments["query"]?.stringValue ?? "")
                payload = .object(["updatedAt": .null, "totals": .object(["positions": .number(Double(all.count)), "quantity": .number(Double(all.reduce(0) { $0 + max($1.quantity, 0) }))]), "items": .array(selected.prefix(call.arguments.limit).map { .object(["id": .string($0.id), "type": .string("оборудование"), "model": .string($0.name), "quantity": .number(Double(max($0.quantity, 0))), "updatedAt": .string($0.receivedAt)]) })])
            default: throw AppServiceError.message("Помощник запросил недоступный источник данных.")
            }
            results.append(AssistantAPIToolResult(name: call.name, payload: payload))
        }
        return results
    }

    private func selectedRecords(
        _ records: [SimpleOneRequestRecord],
        arguments: [String: AssistantJSONValue],
        limit: Int
    ) -> [SimpleOneRequestRecord] {
        let query = arguments["query"]?.stringValue ?? ""
        return Self.filteredRecords(records, query: query).prefix(limit).map { $0 }
    }

    private func requestSummary(_ record: SimpleOneRequestRecord, closed: Bool) -> AssistantJSONValue {
        var value: [String: AssistantJSONValue] = [
            "id": .string(record.id),
            "number": .string(record.number),
            "equipmentType": .string(record.requestType),
            "equipmentModel": .string(record.terminalModel),
            "symptom": .string(record.shortDescription)
        ]
        if closed {
            value["closedAt"] = .string(record.primaryDate)
            value["resolutionCode"] = .string(record.closureCode ?? "")
            value["result"] = .string(record.resolution ?? record.engineerComment)
        } else {
            value["status"] = .string(record.state)
            value["dueAt"] = .string(record.deadline)
        }
        return .object(value)
    }

    private func requestDetails(_ record: SimpleOneRequestRecord) -> AssistantJSONValue {
        .object([
            "id": .string(record.id),
            "number": .string(record.number),
            "status": .string(record.state),
            "dueAt": .string(record.deadline),
            "project": .string(record.clientServiceParent ?? record.assignmentGroup),
            "equipmentType": .string(record.requestType),
            "equipmentModel": .string(record.terminalModel),
            "terminalId": .string(record.terminalID),
            "symptom": .string(record.informationText.isEmpty ? record.shortDescription : record.informationText),
            "errorCode": .string(record.waitingReason ?? ""),
            "performedActions": .string(record.engineerComment),
            "result": .string(record.resolution ?? ""),
            "updatedAt": .string(record.primaryDate)
        ])
    }

    private static func findRecord(
        _ records: [SimpleOneRequestRecord],
        id: String,
        query: String?
    ) -> SimpleOneRequestRecord? {
        if !id.isEmpty, let exact = records.first(where: { matchesIdentifier($0, id: id) }) {
            return exact
        }
        return filteredRecords(records, query: query ?? "").first
    }

    private static func matchesIdentifier(_ record: SimpleOneRequestRecord, id: String) -> Bool {
        guard !id.isEmpty else { return false }
        return [record.id, record.sysID, record.number, record.terminalID]
            .contains { $0.caseInsensitiveCompare(id) == .orderedSame }
    }

    private static func filteredRecords(
        _ records: [SimpleOneRequestRecord],
        query: String
    ) -> [SimpleOneRequestRecord] {
        let tokens = searchTokens(query)
        let sorted = records.sorted { $0.primaryDate.localizedStandardCompare($1.primaryDate) == .orderedDescending }
        guard !tokens.isEmpty else { return sorted }
        let scored = sorted.map { record in
            (record, tokens.reduce(0) { $0 + (record.searchText.contains($1) ? 1 : 0) })
        }
        let matches = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
        return matches.isEmpty ? sorted : matches
    }

    private static func filteredBackpackItems(_ items: [BackpackItem], query: String) -> [BackpackItem] {
        let tokens = searchTokens(query)
        guard !tokens.isEmpty else { return items }
        let matches = items.filter { item in
            let text = "\(item.name) \(item.serialNumber)".folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: .current
            )
            return tokens.contains(where: text.contains)
        }
        return matches.isEmpty ? items : matches
    }

    private static func searchTokens(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    nonisolated private static func dateString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private extension Dictionary where Key == String, Value == AssistantJSONValue {
    var limit: Int { guard let value = self["limit"]?.numberValue, value.isFinite else { return 10 }; return Int(Swift.min(10, Swift.max(1, value))) }
}
private extension AssistantJSONValue {
    var stringValue: String? { guard case .string(let value) = self else { return nil }; return value }
    var numberValue: Double? { guard case .number(let value) = self else { return nil }; return value }
}
