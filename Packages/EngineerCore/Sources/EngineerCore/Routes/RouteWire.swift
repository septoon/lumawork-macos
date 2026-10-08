import Foundation

// Existing RouteDayService request/response semantics, independent of UI.
enum RouteWire {
    static func remoteWorkType(_ dictionary: [String: Any], fallback: RouteWorkType = .pos) -> RouteWorkType {
        RouteWorkType(rawValue: stringValue(dictionary["workType"]).uppercased()) ?? fallback
    }

    static func buildSendPayload(record: RouteDayRecord, date: String) -> [String: Any] {
        [
            "date": date,
            "workType": record.workType.rawValue,
            "distanceKm": record.distanceKm as Any,
            "periodStartOdometer": record.periodStartOdometer as Any,
            "sent": record.sent,
            "stops": record.stops.map { stop in
                [
                    "id": stop.id,
                    "address": stop.address.trimmingCharacters(in: .whitespacesAndNewlines),
                    "org": stop.org.trimmingCharacters(in: .whitespacesAndNewlines),
                    "tid": stop.tid.trimmingCharacters(in: .whitespacesAndNewlines),
                    "reason": stop.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                    "status": statusLabel(for: stop.status),
                    "rejectReason": stop.declineReason.trimmingCharacters(in: .whitespacesAndNewlines),
                    "requestNumber": stop.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines),
                    "coordinateOverride": stop.coordinateOverride.map {
                        ["latitude": $0.latitude, "longitude": $0.longitude] as Any
                    } ?? NSNull()
                ]
            }
        ]
    }

    static func statusLabel(for status: RouteStopStatus) -> String {
        switch status {
        case .done:
            return "Выполнена"
        case .declined:
            return "Отказ"
        case .pending:
            return "В процессе"
        }
    }

    static func extractDay(
        from payload: Any?,
        date: String,
        workType: RouteWorkType
    ) -> [String: Any]? {
        guard let payload else { return nil }

        if let array = payload as? [Any] {
            return array.compactMap { $0 as? [String: Any] }.first {
                ($0["date"] as? String) == date && remoteWorkType($0) == workType
            }
        }

        if let dictionary = payload as? [String: Any] {
            if let records = dictionary["records"] as? [Any] {
                return records.compactMap { $0 as? [String: Any] }.first {
                    ($0["date"] as? String) == date && remoteWorkType($0) == workType
                }
            }
            let storageKey = workType.storageKey(for: date)
            if let days = dictionary["days"] as? [String: Any], let day = days[storageKey] as? [String: Any] {
                return day
            }
            if let day = dictionary[storageKey] as? [String: Any] {
                return day
            }
        }

        return nil
    }

    static func normalizeRemoteDays(from payload: Any?, settings: RouteSettings) -> [RouteDayRecord] {
        guard let payload else { return [] }

        var normalizedByKey: [String: RouteDayRecord] = [:]

        if let array = payload as? [Any] {
            for item in array {
                guard let dictionary = item as? [String: Any] else { continue }
                let date = stringValue(dictionary["date"]).nilIfEmpty
                guard let date,
                      let day = normalizeRemoteDay(dictionary, date: date, fallbackWorkType: .pos, settings: settings) else { continue }
                normalizedByKey[day.workType.storageKey(for: date)] = day
            }
            return Array(normalizedByKey.values)
        }

        guard let dictionary = payload as? [String: Any] else {
            return []
        }

        if let records = dictionary["records"] as? [Any] {
            for item in records {
                guard let rawDay = item as? [String: Any],
                      let date = stringValue(rawDay["date"]).nilIfEmpty,
                      let day = normalizeRemoteDay(rawDay, date: date, fallbackWorkType: .pos, settings: settings) else { continue }
                normalizedByKey[day.workType.storageKey(for: date)] = day
            }
        }

        if let date = stringValue(dictionary["date"]).nilIfEmpty,
           let day = normalizeRemoteDay(dictionary, date: date, fallbackWorkType: .pos, settings: settings) {
            normalizedByKey[day.workType.storageKey(for: date)] = day
        }

        let source = (dictionary["days"] as? [String: Any]) ?? dictionary
        for (storageKey, value) in source {
            guard let rawDay = value as? [String: Any] else { continue }
            let date = stringValue(rawDay["date"]).nilIfEmpty ?? String(storageKey.prefix(10))
            let fallbackWorkType: RouteWorkType = storageKey.hasSuffix("|ARM") ? .arm : .pos
            guard let day = normalizeRemoteDay(
                rawDay,
                date: date,
                fallbackWorkType: fallbackWorkType,
                settings: settings
            ) else { continue }
            normalizedByKey[day.workType.storageKey(for: date)] = day
        }

        return Array(normalizedByKey.values)
    }

    static func normalizeRemoteDay(
        _ raw: [String: Any]?,
        date: String,
        fallbackWorkType: RouteWorkType,
        settings: RouteSettings
    ) -> RouteDayRecord? {
        guard let raw else { return nil }
        let workType = remoteWorkType(raw, fallback: fallbackWorkType)
        let base = RouteDefaults.defaultDay(for: date, workType: workType, settings: settings)
        let rawStops = (raw["stops"] as? [Any])?.compactMap(normalizeRemoteStop)
        return RouteDayRecord(
            date: date,
            workType: workType,
            stops: RouteDefaults.hydrateStops(raw: rawStops, base: base.stops),
            distanceKm: intValue(raw["distanceKm"]) ?? intValue(raw["distance_km"]),
            periodStartOdometer: intValue(raw["periodStartOdometer"]) ?? intValue(raw["period_start_odometer"]),
            reportedDistanceKm: doubleValue(raw["distanceKm"]) ?? doubleValue(raw["distance_km"]),
            routeSummary: stringValue(raw["routeSummary"]).nilIfEmpty ?? stringValue(raw["route"]).nilIfEmpty,
            requestNumbersSummary: stringValue(raw["requestNumbersSummary"]).nilIfEmpty ?? stringValue(raw["request_numbers"]).nilIfEmpty,
            reportedPeriodStartOdometer: intValue(raw["reportedPeriodStartOdometer"]) ?? intValue(raw["periodStartOdometer"]) ?? intValue(raw["period_start_odometer"]),
            fuelDate: stringValue(raw["fuelDate"]).nilIfEmpty ?? stringValue(raw["fuel_date"]).nilIfEmpty,
            fuelLiters: doubleValue(raw["fuelLiters"]) ?? doubleValue(raw["fuel_liters"]),
            fuelCostRub: doubleValue(raw["fuelCostRub"]) ?? doubleValue(raw["fuel_cost_rub"]),
            sent: (raw["sent"] as? Bool) ?? false
        )
    }

    static func normalizeRemoteStop(_ raw: Any) -> RouteStop? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        return RouteStop(
            id: stringValue(dictionary["id"]).nilIfEmpty ?? UUID().uuidString,
            address: stringValue(dictionary["address"]),
            org: stringValue(dictionary["org"]),
            tid: stringValue(dictionary["tid"]),
            reason: stringValue(dictionary["reason"]),
            status: normalizeRemoteStatus(dictionary["status"]),
            declineReason: stringValue(dictionary["declineReason"]).nilIfEmpty
                ?? stringValue(dictionary["rejectReason"]),
            requestNumber: stringValue(dictionary["requestNumber"]),
            coordinateOverride: normalizedCoordinate(dictionary["coordinateOverride"] ?? (dictionary["payload"] as? [String: Any])?["coordinateOverride"])
        )
    }

    static func normalizedCoordinate(_ raw: Any?) -> AppleRouteCoordinate? {
        guard let value = raw as? [String: Any],
              let latitude = doubleValue(value["latitude"]), let longitude = doubleValue(value["longitude"]) else { return nil }
        let coordinate = AppleRouteCoordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }

    static func normalizeRemoteStatus(_ raw: Any?) -> RouteStopStatus {
        let value = stringValue(raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("decline") || value.contains("отказ") {
            return .declined
        }
        if value.contains("done") || value.contains("выполн") {
            return .done
        }
        if value == RouteStopStatus.done.rawValue {
            return .done
        }
        if value == RouteStopStatus.declined.rawValue {
            return .declined
        }
        return .pending
    }

}

nonisolated func stringValue(_ value: Any?, default fallback: String = "") -> String {
    if value == nil || value is NSNull {
        return fallback
    }
    if let string = value as? String {
        return string
    }
    return String(describing: value!)
}

func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    default:
        return nil
    }
}

func intValue(_ value: Any?) -> Int? {
    guard let number = doubleValue(value) else {
        return nil
    }
    return Int(number)
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
