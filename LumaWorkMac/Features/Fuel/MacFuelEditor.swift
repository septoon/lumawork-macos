import SwiftUI
import EngineerCore

struct MacFuelEditor: View {
    @Bindable var model: MacFuelEditorModel
    let repository: GsmFuelRepository
    let coordinator: EngineerApplicationCoordinator
    let fuelTypes: [String]
    let finished: (FuelRecord?) -> Void
    @State private var confirmsCancel = false
    private var validation: String? { do { _ = try model.draft.record(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(model.base == nil ? "Новая запись топлива" : "Запись топлива").font(.title2); Spacer() }.padding(16)
            Divider()
            Form {
                Picker("Запись", selection: $model.draft.recordType) {
                    Text("Топливо").tag(FuelRecord.RecordType.fuel)
                    Text("Корректировка").tag(FuelRecord.RecordType.adjustment)
                }
                TextField("Дата (YYYY-MM-DD)", text: $model.draft.date)
                if model.draft.recordType == .fuel {
                    TextField("Пробег, км", text: $model.draft.mileage)
                    TextField("Бензин, л", text: $model.draft.liters)
                    TextField("Стоимость, ₽", text: $model.draft.cost)
                    Picker("Тип топлива", selection: $model.draft.fuelType) {
                        Text("Не выбран").tag("")
                        ForEach(Array(Set(fuelTypes + [model.draft.fuelType]).filter { !$0.isEmpty }).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Picker("Корректировка", selection: $model.draft.adjustmentKind) {
                        Text("Выплата компенсации").tag(FuelRecord.AdjustmentKind.compensationPayment)
                        Text("Вычет долга").tag(FuelRecord.AdjustmentKind.debtDeduction)
                    }
                    TextField("Месяц (YYYY-MM)", text: $model.draft.month)
                    TextField("Сумма, ₽", text: $model.draft.amount)
                    if model.draft.adjustmentKind == .debtDeduction {
                        TextField("Литры", text: $model.draft.liters)
                        TextField("Остаток долга, ₽", text: $model.draft.carryover)
                    }
                }
                TextField("Комментарий", text: $model.draft.comment, axis: .vertical).lineLimit(2...4)
            }.formStyle(.grouped).disabled(model.isSaving)
            if let message = model.error ?? validation { Text(message).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16) }
            HStack {
                if model.isSaving { ProgressView().controlSize(.small) }
                Text("Сохранение отправляет запись на сервер.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { if model.isDirty { confirmsCancel = true } else { finished(nil) } }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction).disabled(validation != nil || repository.isMutating)
            }.padding(16).disabled(model.isSaving)
        }
        .frame(width: 580, height: 550).interactiveDismissDisabled(model.isDirty || model.isSaving)
        .confirmationDialog("Отменить изменения записи?", isPresented: $confirmsCancel) { Button("Не сохранять", role: .destructive) { finished(nil) } }
    }
    private func save() {
        guard !model.isSaving, coordinator.accepts(model.context) else { return }
        model.isSaving = true; model.error = nil
        Task {
            defer { model.isSaving = false }
            do {
                let saved = try await repository.saveFuel(model.draft.record(), base: model.base)
                guard coordinator.accepts(model.context) else { return }; finished(saved)
            } catch { if coordinator.accepts(model.context), !AppErrorClassification.isCancellation(error) { model.error = error.localizedDescription } }
        }
    }
}
