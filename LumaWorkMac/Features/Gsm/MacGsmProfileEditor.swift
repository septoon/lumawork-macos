import SwiftUI
import EngineerCore

struct MacGsmProfileEditor: View {
    @Bindable var model: MacGsmEditorModel
    let repository: GsmFuelRepository
    let coordinator: EngineerApplicationCoordinator
    let finished: (Bool) -> Void
    @State private var confirmsCancel = false
    private var validation: String? { do { _ = try model.record(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Профиль ГСМ").font(.title2); Spacer() }.padding(16)
            Divider()
            Form {
                Section("Сотрудник") {
                    field("ФИО", \.employeeFullName); field("Фамилия И.О.", \.employeeShortName); field("И.О. Фамилия для подписи", \.employeeReportSignName)
                    field("Должность", \.employeeJobTitle); field("Компания", \.employeeCompany)
                    field("Адрес", \.employeeAddress); field("Телефон", \.employeePhone)
                }
                Section("Уполномоченный представитель") { field("ФИО", \.authorizedFullName); field("Фамилия И.О.", \.authorizedShortName) }
                Section("Проекты") {
                    projectPicker("POS", binding: $model.draft.posProjectID)
                    projectPicker("АРМ", binding: $model.draft.armProjectID)
                    LabeledContent("Код бюджета", value: model.draft.budgetCode)
                }
                Section("Автомобиль и топливо") {
                    if model.draft.vehicleID != nil { Text("Привязка к выбранному автомобилю сохранена.").foregroundStyle(.secondary).font(.caption) }
                    field("Модель", \.carModel).disabled(!model.canEditVehicleFields); field("Госномер", \.licensePlate).disabled(!model.canEditVehicleFields)
                    field("Водительское удостоверение", \.driverLicenseNumber); field("Топливная карта", \.fuelCardNumber)
                    TextField("Норма, л/100 км", text: $model.fuelNorm)
                    ForEach(Array(Set((repository.profile?.availableFuelTypes ?? []) + model.draft.fuelTypes)).sorted(), id: \.self) { type in
                        Toggle(type, isOn: Binding(get: { model.draft.fuelTypes.contains(type) }, set: { selected in
                            if selected { if !model.draft.fuelTypes.contains(type) { model.draft.fuelTypes.append(type) } }
                            else { model.draft.fuelTypes.removeAll { $0 == type } }
                        })).toggleStyle(.checkbox)
                    }
                    TextField("Одометр по умолчанию", text: $model.startOdometer).disabled(!model.canEditInitialOdometer)
                    if !model.canEditInitialOdometer { Text("Для маршрута используйте одометр из предыдущего отчёта.").font(.caption).foregroundStyle(.secondary) }
                    field("Первый месяц отчётов (YYYY-MM)", \.reportStartMonth)
                }
            }.formStyle(.grouped).disabled(model.isSaving)
            if let message = model.error ?? validation { Text(message).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                if model.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { if model.isDirty { confirmsCancel = true } else { finished(false) } }.keyboardShortcut(.cancelAction)
                Button("Сохранить на сервере") { save() }.keyboardShortcut(.defaultAction).disabled(validation != nil || repository.isMutating)
            }.padding(16).disabled(model.isSaving)
        }
        .frame(width: 650, height: 680).interactiveDismissDisabled(model.isDirty || model.isSaving)
        .confirmationDialog("Отменить изменения профиля?", isPresented: $confirmsCancel) { Button("Не сохранять", role: .destructive) { finished(false) } }
    }
    private func field(_ label: String, _ key: WritableKeyPath<GsmProfile, String>) -> some View { TextField(label, text: Binding(get: { model.draft[keyPath: key] }, set: { model.draft[keyPath: key] = $0 })) }
    private func projectPicker(_ label: String, binding: Binding<String?>) -> some View {
        Picker(label, selection: binding) {
            Text("Не выбран").tag(nil as String?)
            if let selected = binding.wrappedValue, !repository.projects.contains(where: { $0.id == selected }) { Text("Текущий проект").tag(Optional(selected)) }
            ForEach(repository.projects) { Text($0.name).tag(Optional($0.id)) }
        }.onChange(of: binding.wrappedValue) { _, id in
            if label == "POS", let option = repository.projects.first(where: { $0.id == id }) { model.draft.projectName = option.name; model.draft.budgetCode = option.budgetCode }
        }
    }
    private func save() {
        guard !model.isSaving, coordinator.accepts(model.context) else { return }
        model.isSaving = true; model.error = nil
        Task {
            defer { model.isSaving = false }
            do { _ = try await repository.saveProfile(model.record(), base: model.base); guard coordinator.accepts(model.context) else { return }; finished(true) }
            catch { if coordinator.accepts(model.context), !AppErrorClassification.isCancellation(error) { model.error = error.localizedDescription } }
        }
    }
}
