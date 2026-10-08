import Foundation
import Observation
import EngineerCore

@MainActor @Observable
final class MacRouteWorkspace {
    var selectedDate = Date()
    var workType = RouteWorkType.pos
    var selectedStopID: String?
    var draft: RouteDraftController?
    var isLoading = false
    var isBusy = false
    var error: String?
    var notice: String?
    var isArchivePresented = false
    var isMapPresented = false
    var isSendConfirmationPresented = false
    var isRemotePresented = false
    var isLocalReloadConfirmationPresented = false
    var key: RouteDayKey { RouteDayKey(date: MacRouteDate.key(selectedDate), workType: workType) }

    func load(repository: RouteDayRepository, coordinator: EngineerApplicationCoordinator, force: Bool = false) async {
        let key = self.key
        guard let context = coordinator.context else { return }
        let isNewDay = draft?.record.key != key
        isLoading = true; error = nil; notice = nil
        if isNewDay { draft = nil; selectedStopID = nil }
        defer { if self.key == key { isLoading = false } }
        do {
            let cached = try await repository.prepare(key)
            try Task.checkCancellation()
            guard coordinator.accepts(context), self.key == key else { return }
            if draft == nil {
                let record = cached?.remote ?? RouteDefaults.defaultDay(for: key.date, workType: key.workType, settings: repository.settings)
                let controller = RouteDraftController(record: record, remote: cached?.remote, draft: cached?.draft)
                if cached?.remote == nil && cached?.draft?.base == nil { controller.setBaseToEmpty() }
                draft = controller; selectedStopID = controller.record.stops.dropFirst().first?.id
            }
            let remote = try await repository.load(key, force: force)
            try Task.checkCancellation()
            guard coordinator.accepts(context), self.key == key else { return }
            let selectedIndex = draft?.record.stops.firstIndex { $0.id == selectedStopID }
            draft?.receive(remote: remote)
            if let draft, !draft.record.stops.contains(where: { $0.id == selectedStopID }) {
                let index = min(selectedIndex ?? 1, max(0, draft.record.stops.count - 1))
                selectedStopID = draft.record.stops.isEmpty ? nil : draft.record.stops[index].id
            }
            if workType == .arm { try await repository.loadOfficeAddresses() }
        } catch {
            if !AppErrorClassification.isCancellation(error), coordinator.accepts(context), self.key == key { self.error = error.localizedDescription }
        }
    }
    func save(repository: RouteDayRepository) async throws {
        guard let draft, !isBusy else { throw RouteRepositoryError.busy }
        let record = draft.record
        isBusy = true; defer { isBusy = false }
        let saved = try await repository.saveLocal(record, base: draft.base, replacing: draft.savedRevision)
        draft.markSaved(saved); notice = "Черновик сохранён на этом Mac."; error = nil
    }
    func saveShowingError(repository: RouteDayRepository) async {
        do { try await save(repository: repository) }
        catch { if !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
    }
    func send(repository: RouteDayRepository) async {
        guard let draft, !isBusy, draft.validationMessage == nil else { return }
        do {
            if draft.isDirty || draft.savedRevision == nil { try await save(repository: repository) }
            isBusy = true; defer { isBusy = false }
            let result = try await repository.send(draft.record, base: draft.base)
            draft.markSent(result)
            selectedStopID = result.stops.dropFirst().first?.id
            notice = "Маршрут отправлен."; error = nil
        } catch {
            if !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription }
        }
    }
    func useRemote(repository: RouteDayRepository) async {
        guard let draft, let remote = draft.remote, !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do {
            try await repository.discardLocal(draft.record.key, revision: draft.savedRevision)
            draft.useRemote(remote); selectedStopID = remote.stops.dropFirst().first?.id
            error = nil; notice = nil; isRemotePresented = false
        } catch { self.error = error.localizedDescription }
    }
    func reloadLocal(repository: RouteDayRepository, coordinator: EngineerApplicationCoordinator) async {
        guard let draft, !isBusy, let context = coordinator.context else { return }
        let key = self.key
        isBusy = true; defer { isBusy = false }
        do {
            let cached = try await repository.prepare(key)
            try Task.checkCancellation()
            guard coordinator.accepts(context), self.key == key else { return }
            if let saved = cached?.draft {
                draft.useSavedDraft(saved); draft.receive(remote: cached?.remote)
            } else {
                let record = cached?.remote ?? RouteDefaults.defaultDay(for: key.date, workType: key.workType, settings: repository.settings)
                let restored = RouteDraftController(record: record, remote: cached?.remote)
                if cached?.remote == nil { restored.setBaseToEmpty() }
                self.draft = restored
            }
            selectedStopID = self.draft?.record.stops.dropFirst().first?.id
            error = nil; notice = nil
        } catch { if !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
    }
}

enum MacRouteDate {
    static func key(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
    static func date(_ key: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return formatter.date(from: key)
    }
}
