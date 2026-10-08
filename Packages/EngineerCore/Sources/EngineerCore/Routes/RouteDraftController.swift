import Foundation
import Observation

// One controller per window/day; network/cache data belongs to RouteDayRepository.
@MainActor @Observable
public final class RouteDraftController {
    public private(set) var record: RouteDayRecord
    public private(set) var remote: RouteDayRecord?
    public private(set) var base: RouteDayRecord?
    public private(set) var savedRevision: UUID?
    private var savedRecord: RouteDayRecord
    public var isDirty: Bool { record != savedRecord }
    public var hasRemoteConflict: Bool { !RouteFingerprint.matches(base, remote) }
    public var validationMessage: String? { Self.validationMessage(record) }

    public init(record: RouteDayRecord, remote: RouteDayRecord? = nil, draft: RouteSavedDraft? = nil) {
        self.record = draft?.record ?? record; savedRecord = draft?.record ?? record
        self.remote = draft != nil ? remote : (remote ?? record)
        base = draft != nil ? draft?.base : (remote ?? record); savedRevision = draft?.revision
    }
    public func setBaseToEmpty() { remote = nil; base = nil }
    public func receive(remote: RouteDayRecord?) {
        self.remote = remote
        // Saved local drafts must survive refresh too, not just in-memory edits.
        guard !isDirty, savedRevision == nil, let remote else { return }
        record = remote; savedRecord = remote; base = remote
    }
    public func markSaved(_ draft: RouteSavedDraft) {
        savedRecord = draft.record; savedRevision = draft.revision; base = draft.base
    }
    public func markSent(_ result: RouteDayRecord) {
        record = result; savedRecord = result; remote = result; base = result; savedRevision = nil
    }
    public func discard() { record = savedRecord }
    // Explicit user choice; ordinary refresh must retain this window's edits.
    public func useSavedDraft(_ draft: RouteSavedDraft) {
        record = draft.record; savedRecord = draft.record; base = draft.base; savedRevision = draft.revision
    }
    public func useRemote(_ value: RouteDayRecord) {
        record = value; savedRecord = value; remote = value; base = value; savedRevision = nil
    }
    public func setDistance(_ value: Int?) { record.distanceKm = value; record.sent = false }
    @discardableResult public func applyMapDistance(_ snapshot: RouteMapSnapshot, source: RouteDayRecord, plan: RouteMapPlan) -> Bool {
        guard source.key == record.key, source.stops.count == record.stops.count,
              zip(source.stops, record.stops).allSatisfy({ $0.id == $1.id && $0.address == $1.address }),
              plan.addresses == RouteMapPlan(stops: record.stops).addresses,
              record.stops.indices.allSatisfy({ i in record.stops[i].coordinateOverride == nil || record.stops[i].coordinateOverride == plan.coordinateOverrides[i] }),
              snapshot.matches(plan), snapshot.canApplyDistance else { return false }
        setDistance(snapshot.distanceKm); return true
    }
    public func setOdometer(_ value: Int?) { record.periodStartOdometer = value; record.sent = false }
    public func updateStop(_ id: String, address: String? = nil, org: String? = nil, tid: String? = nil, reason: String? = nil, status: RouteStopStatus? = nil, declineReason: String? = nil, requestNumber: String? = nil, coordinate: AppleRouteCoordinate?? = nil) {
        guard let index = record.stops.firstIndex(where: { $0.id == id }) else { return }
        if let address, address != record.stops[index].address { record.stops[index].address = address; record.distanceKm = nil }
        if let org { record.stops[index].org = org }
        if let tid { record.stops[index].tid = tid }
        if let reason { record.stops[index].reason = reason }
        if let status, index > 0, index < record.stops.count - 1 { record.stops[index].status = status }
        if let declineReason { record.stops[index].declineReason = declineReason }
        if let requestNumber { record.stops[index].requestNumber = requestNumber }
        if let coordinate { record.stops[index].coordinateOverride = coordinate; record.distanceKm = nil }
        record.sent = false
    }
    public func addStop() { record.stops.insert(RouteStop(), at: max(1, record.stops.count - 1)); invalidateDistance() }
    public func removeStop(_ id: String) {
        guard let index = middleIndex(id), record.stops.count > 3 else { return }
        record.stops.remove(at: index); invalidateDistance()
    }
    public func moveStop(_ id: String, offset: Int) {
        guard let index = middleIndex(id), (1..<(record.stops.count - 1)).contains(index + offset) else { return }
        record.stops.swapAt(index, index + offset); invalidateDistance()
    }
    private func middleIndex(_ id: String) -> Int? {
        guard let index = record.stops.firstIndex(where: { $0.id == id }), index > 0, index < record.stops.count - 1 else { return nil }
        return index
    }
    private func invalidateDistance() { record.distanceKm = nil; record.sent = false }

    public static func validationMessage(_ record: RouteDayRecord) -> String? {
        guard record.stops.count >= 3, record.stops.dropFirst().dropLast().contains(where: {
            !$0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.requestNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return "Нет данных для отправки." }
        if let km = record.distanceKm, km < 0 { return "Пробег не может быть отрицательным." }
        if let km = record.periodStartOdometer, km < 0 { return "Одометр не может быть отрицательным." }
        guard record.date >= "2026-04-01" else { return nil }
        if record.distanceKm == nil { return "Начиная с 2026-04-01 заполните пробег за день." }
        if record.periodStartOdometer == nil { return "Начиная с 2026-04-01 заполните одометр на начало месяца." }
        if record.workType == .arm, record.stops.dropFirst().dropLast().contains(where: { $0.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return "Для АРМ выберите адрес отделения у каждой точки."
        }
        return nil
    }
}

public enum RouteFingerprint {
    public static func matches(_ lhs: RouteDayRecord?, _ rhs: RouteDayRecord?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return canonical(lhs) == canonical(rhs)
    }
    private static func canonical(_ record: RouteDayRecord) -> Data? {
        var body = RouteWire.buildSendPayload(record: record, date: record.date)
        body.removeValue(forKey: "sent")
        body["stops"] = (body["stops"] as? [[String: Any]])?.map { stop in var copy = stop; copy.removeValue(forKey: "id"); return copy }
        return try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }
}
