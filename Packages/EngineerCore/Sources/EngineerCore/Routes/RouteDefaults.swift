import Foundation

public enum RouteDefaults {
    public static func defaultDay(
        for date: String,
        workType: RouteWorkType = .pos,
        settings: RouteSettings
    ) -> RouteDayRecord {
        RouteDayRecord(
            date: date,
            workType: workType,
            stops: [
                makeStop(
                    id: "start-\(date)",
                    address: settings.startAddress,
                    reason: "Подготовка оборудования",
                    status: .done
                ),
                makeStop(id: "middle-\(date)", status: .pending),
                makeStop(
                    id: "finish-\(date)",
                    address: settings.endAddress,
                    reason: "Сдача оборудования",
                    status: .done
                )
            ],
            distanceKm: nil,
            periodStartOdometer: nil,
            sent: false
        )
    }

    static func hydrateStops(raw: [RouteStop]?, base: [RouteStop]) -> [RouteStop] {
        let firstReason = base.first?.reason.nilIfEmpty ?? "Подготовка оборудования"
        let lastReason = base.last?.reason.nilIfEmpty ?? "Сдача оборудования"

        guard let raw, !raw.isEmpty else {
            return base.enumerated().map { index, stop in
                var copy = stop
                copy.status = index == 0 || index == base.count - 1 ? .done : .pending
                copy.reason = index == 0 ? firstReason : index == base.count - 1 ? lastReason : stop.reason
                return copy
            }
        }

        var cloned = raw.enumerated().map { index, stop -> RouteStop in
            let isEdge = index == 0 || index == raw.count - 1
            let fallbackStatus: RouteStopStatus = isEdge ? .done : .pending
            return RouteStop(
                id: stop.id.nilIfEmpty ?? base[safe: index]?.id ?? UUID().uuidString,
                address: stop.address,
                org: stop.org,
                tid: stop.tid,
                reason: stop.reason,
                status: normalizeStatus(stop.status.rawValue, fallback: fallbackStatus),
                declineReason: stop.declineReason,
                requestNumber: stop.requestNumber,
                coordinateOverride: stop.coordinateOverride
            )
        }

        if cloned.count < 2 {
            return defaultFallback(base: base, firstReason: firstReason, lastReason: lastReason)
        }

        if cloned.count == 2 {
            cloned.insert(base[safe: 1] ?? makeStop(status: .pending), at: 1)
        }

        let lastIndex = cloned.count - 1
        cloned[0].reason = cloned[0].reason.nilIfEmpty ?? firstReason
        cloned[0].status = .done
        cloned[lastIndex].reason = cloned[lastIndex].reason.nilIfEmpty ?? lastReason
        cloned[lastIndex].status = .done

        return cloned
    }

    private static func defaultFallback(base: [RouteStop], firstReason: String, lastReason: String) -> [RouteStop] {
        base.enumerated().map { index, stop in
            var copy = stop
            copy.status = index == 0 || index == base.count - 1 ? .done : .pending
            copy.reason = index == 0 ? firstReason : index == base.count - 1 ? lastReason : stop.reason
            return copy
        }
    }

    private static func makeStop(
        id: String = UUID().uuidString,
        address: String = "",
        org: String = "",
        tid: String = "",
        reason: String = "",
        status: RouteStopStatus = .pending,
        declineReason: String = "",
        requestNumber: String = ""
    ) -> RouteStop {
        RouteStop(
            id: id,
            address: address,
            org: org,
            tid: tid,
            reason: reason,
            status: status,
            declineReason: declineReason,
            requestNumber: requestNumber
        )
    }

    private static func normalizeStatus(_ raw: String, fallback: RouteStopStatus) -> RouteStopStatus {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == RouteStopStatus.pending.rawValue {
            return .pending
        }
        if lowered == RouteStopStatus.done.rawValue || lowered.contains("done") || lowered.contains("выполн") {
            return .done
        }
        if lowered == RouteStopStatus.declined.rawValue || lowered.contains("decline") || lowered.contains("отказ") {
            return .declined
        }
        return fallback
    }

}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
