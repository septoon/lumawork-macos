import SwiftUI
import EngineerCore

struct MacVehicleEditor: View {
    @Bindable var model: MacVehicleEditorModel
    let repository: VehicleMaintenanceRepository
    let coordinator: EngineerApplicationCoordinator
    let completion: (Vehicle?) -> Void
    private var validation: String? { do { _ = try model.draft.payload(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.base == nil ? "Добавить автомобиль" : "Автомобиль").font(.title2)
            ScrollView {
                Form {
                    TextField("Название", text: $model.draft.customName)
                    HStack { TextField("Марка", text: $model.draft.make); TextField("Модель", text: $model.draft.model) }
                    HStack { TextField("Поколение", text: $model.draft.generation); TextField("Год выпуска", text: $model.draft.year) }
                    HStack { TextField("Кузов", text: $model.draft.bodyType); TextField("Цвет", text: $model.draft.colorName) }
                    TextField("Госномер", text: $model.draft.licensePlate).onChange(of: model.draft.licensePlate) { _, value in model.draft.licensePlate = VehicleInputValidation.formatPlate(value) }
                    TextField("VIN", text: $model.draft.vin).onChange(of: model.draft.vin) { _, value in model.draft.vin = VehicleInputValidation.normalizedVIN(value) }
                    HStack { TextField("СТС", text: $model.draft.sts); TextField("ПТС", text: $model.draft.pts) }
                    TextField("Пробег, км", text: $model.draft.currentMileageKm)
                    HStack { TextField("Объём, см³", text: $model.draft.engineVolumeCm3); TextField("Мощность, л. с.", text: $model.draft.enginePowerHp) }
                    Toggle("Основной автомобиль", isOn: $model.draft.isPrimary)
                }
            }
            if let message = model.error ?? validation { Text(message).font(.callout).foregroundStyle(.red) }
            if repository.requiresRefresh { Button("Обновить данные") { Task { try? await repository.load(force: true) } }.disabled(repository.isSaving) }
            HStack {
                Button("Отмена") { completion(nil) }.keyboardShortcut(.cancelAction).disabled(model.isSaving)
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction).disabled(validation != nil || model.isSaving || repository.isSaving || repository.requiresRefresh)
            }
        }.padding(20).frame(width: 620, height: 540).interactiveDismissDisabled(model.isDirty || model.isSaving)
    }
    private func save() {
        let value = model.draft; model.isSaving = true; model.error = nil
        Task {
            defer { model.isSaving = false }
            do { let saved = try await repository.saveVehicle(value, base: model.base, expectedContext: model.context); guard coordinator.accepts(model.context) else { return }; completion(saved) }
            catch { if coordinator.accepts(model.context), !AppErrorClassification.isCancellation(error) { model.error = repository.error ?? error.localizedDescription } }
        }
    }
}

struct MacMaintenanceEditor: View {
    @Bindable var model: MacMaintenanceEditorModel
    let vehicles: [Vehicle]
    let repository: VehicleMaintenanceRepository
    let coordinator: EngineerApplicationCoordinator
    let completion: () -> Void
    private var validation: String? { do { _ = try model.input(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Обслуживание автомобиля").font(.title2)
            Form {
                Picker("Автомобиль", selection: $model.vehicleID) {
                    if model.vehicleID.isEmpty { Text("Не указан").tag("") }
                    ForEach(vehicles) { Text($0.displayName).tag($0.id) }
                }
                DatePicker("Дата", selection: $model.date, displayedComponents: .date)
                TextField("Процедура", text: $model.procedure)
                TextField("Пробег, км", text: $model.mileage)
                TextField("Стоимость работы, ₽", text: $model.workCost)
            }
            HStack { Text("Запчасти").font(.headline); Spacer(); Button("Добавить") { model.parts.append(.init()) } }
            ScrollView {
                VStack {
                    ForEach($model.parts) { $part in
                        HStack {
                            TextField("Название", text: $part.name)
                            TextField("Стоимость, ₽", text: $part.cost).frame(width: 130)
                            Button { model.parts.removeAll { $0.id == part.id } } label: { Image(systemName: "minus.circle") }.help("Удалить запчасть")
                        }
                    }
                }
            }.frame(minHeight: 90, maxHeight: 180)
            if let message = model.error ?? validation { Text(message).foregroundStyle(.red) }
            if repository.requiresRefresh { Button("Обновить данные") { Task { try? await repository.load(force: true) } }.disabled(repository.isSaving) }
            HStack {
                Button("Отмена", action: completion).keyboardShortcut(.cancelAction).disabled(model.isSaving)
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction).disabled(validation != nil || model.isSaving || repository.isSaving || repository.requiresRefresh)
            }
        }.padding(20).frame(width: 600).interactiveDismissDisabled(model.isDirty || model.isSaving)
    }
    private func save() {
        do {
            let input = try model.input(); model.isSaving = true; model.error = nil
            Task {
                defer { model.isSaving = false }
                do { _ = try await repository.saveMaintenance(input, base: model.base, expectedContext: model.context); guard coordinator.accepts(model.context) else { return }; completion() }
                catch { if coordinator.accepts(model.context), !AppErrorClassification.isCancellation(error) { model.error = repository.error ?? error.localizedDescription } }
            }
        } catch { model.error = error.localizedDescription }
    }
}
