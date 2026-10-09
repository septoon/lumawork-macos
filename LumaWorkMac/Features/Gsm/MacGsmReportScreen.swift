import SwiftUI
import EngineerCore

struct MacGsmReportScreen: View {
    @Bindable var workspace: MacFuelWorkspace
    let repository: GsmFuelRepository
    let coordinator: EngineerApplicationCoordinator
    @State var selectedDate: Date
    var applyOdometer: ((String, Int) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSend = false
    @State private var odometer: Int?
    @State private var isLoadingOdometer = false
    @State private var notice: String?
    @State private var error: String?
    private var month: String { String(MacRouteDate.key(selectedDate).prefix(7)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Отчёт ГСМ").font(.title2); Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(repository.isMutating)
            }
            DatePicker("Месяц отчёта", selection: $selectedDate, displayedComponents: .date).disabled(repository.isMutating)
            Text(GsmFuelFormatting.monthLabel(month)).font(.headline)
            if let profile = repository.profile?.profile {
                LabeledContent("Сотрудник", value: profile.employeeFullName.isEmpty ? "Не заполнен" : profile.employeeFullName)
                LabeledContent("Автомобиль", value: [profile.carModel, profile.licensePlate].filter { !$0.isEmpty }.joined(separator: " · "))
                LabeledContent("Топливо", value: profile.fuelTypes.joined(separator: ", "))
                Button("Настроить профиль ГСМ") {
                    guard let context = coordinator.context else { return }
                    workspace.profileEditor = MacGsmEditorModel(profile: profile, context: context)
                }.disabled(repository.isMutating)
            } else if repository.isLoadingGsm { ProgressView("Загрузка профиля…") }
            else { Text(repository.gsmError ?? "Профиль ГСМ пока не загружен.").foregroundStyle(.secondary) }
            Divider()
            HStack {
                if isLoadingOdometer { ProgressView().controlSize(.small) }
                Text(odometer.map { "Одометр из предыдущего отчёта: \($0) км" } ?? "Одометр из предыдущего отчёта не найден.").textSelection(.enabled)
                Spacer()
                if let odometer, let applyOdometer { Button("Применить к маршруту") { applyOdometer(month, odometer) } }
            }
            Text("Сервер сформирует Excel-отчёт и отправит его на \(coordinator.session?.user.email ?? "почту аккаунта"). Используются сохранённые на сервере маршруты, топливо и профиль.").foregroundStyle(.secondary)
            if let notice { Label(notice, systemImage: "info.circle").textSelection(.enabled) }
            if let message = error ?? repository.gsmError ?? repository.cacheWarning { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                Button("Обновить профиль") { Task { try? await repository.loadGsm(force: true) } }.disabled(repository.isMutating || repository.isLoadingGsm)
                Spacer()
                if repository.isMutating { ProgressView().controlSize(.small) }
                Button("Сформировать и отправить") { confirmsSend = true }
                    .disabled(repository.profile == nil || repository.profile?.profile == .empty || repository.isMutating || repository.isLoadingGsm)
            }
        }
        .padding(20).frame(width: 650, height: 500)
        .interactiveDismissDisabled(repository.isMutating)
        .confirmationDialog("Отправить отчёт за \(month)?", isPresented: $confirmsSend) {
            Button("Сформировать и отправить") { send() }
        } message: { Text("Письмо будет отправлено на \(coordinator.session?.user.email ?? "почту аккаунта").") }
        .sheet(item: $workspace.profileEditor) { model in
            MacGsmProfileEditor(model: model, repository: repository, coordinator: coordinator) { saved in
                workspace.profileEditor = nil; if saved { notice = "Профиль ГСМ сохранён." }
            }
        }
        .task { do { try await repository.prepare(); try await repository.loadGsm() } catch { } }
        .task(id: month) { await loadOdometer() }
        .onChange(of: month) { _, _ in notice = nil; error = nil }
    }
    private func loadOdometer() async {
        let requested = month; guard let context = coordinator.context else { return }
        odometer = nil; isLoadingOdometer = true
        defer { if month == requested { isLoadingOdometer = false } }
        do {
            let result = try await repository.startOdometer(month: requested); try Task.checkCancellation()
            guard month == requested, coordinator.accepts(context) else { return }; odometer = result
        } catch { if month == requested, coordinator.accepts(context), !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
    }
    private func send() {
        let requested = month; guard let context = coordinator.context else { return }
        error = nil; notice = nil
        Task {
            do { let result = try await repository.sendReport(month: requested); guard coordinator.accepts(context), month == requested else { return }; notice = result.message }
            catch { if coordinator.accepts(context), month == requested, !AppErrorClassification.isCancellation(error) { self.error = error.localizedDescription } }
        }
    }
}
