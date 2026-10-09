import SwiftUI
import Charts
import EngineerCore

private struct SalaryTableRow: Identifiable { let entry: SalaryEntry; var id: String { entry.stableID } }
struct MacSalaryScreen: View {
    @Bindable var workspace: MacSalaryWorkspace
    let repository: SalaryRepository
    let access: SalaryAccess
    let authenticator: MacSalaryAuthenticator
    let coordinator: EngineerApplicationCoordinator
    @State private var pendingDelete: SalaryEntry?
    private var authorized: Bool { access.accepts(workspace.grant) }
    private var months: [SalaryMonth] { SalaryMonth.group(repository.entries(grant: workspace.grant)) }
    private var selectedMonth: SalaryMonth? { months.first { $0.month == workspace.month } }
    var body: some View {
        Group { if authorized { content } else { gate } }
            .task {
                guard !Task.isCancelled else { return }
                repository.synchronizeSession()
                workspace.prepare(authenticator: authenticator, coordinator: coordinator)
                if let user = coordinator.session?.user, authenticator.canAutomaticallyAuthenticate(user.id) { await workspace.systemUnlock(authenticator: authenticator, access: access, coordinator: coordinator, automatically: true) }
            }
            .task(id: authorized) { if authorized, let grant = workspace.grant { try? await repository.load(grant: grant); reconcile() } }
            .onChange(of: months) { _, _ in reconcile() }
            .onChange(of: authorized) { _, value in if !value { pendingDelete = nil; workspace.discardEditor() } }
            .onDisappear { workspace.isPresented = false; workspace.lock(access: access, authenticator: authenticator) }
            .sheet(item: $workspace.editor) { model in
                MacSalaryEditor(model: model, repository: repository, access: access, coordinator: coordinator) { saved in workspace.editor = nil; if let saved { workspace.month = saved.accrualMonthKey; workspace.selection = saved.stableID; workspace.notice = "Выплата сохранена." } }
            }
            .confirmationDialog("Удалить выплату с сервера?", isPresented: Binding(get: { pendingDelete != nil && authorized }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Удалить", role: .destructive) { if let base = pendingDelete, let grant = workspace.grant { remove(base, grant: grant) }; pendingDelete = nil }
            }
    }
    private var gate: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Зарплата", systemImage: "lock.fill").font(.title2)
            Text(workspace.mode == .setup ? "Задайте PIN из четырёх цифр для этого аккаунта." : "Введите PIN, чтобы открыть выплаты.").foregroundStyle(.secondary)
            if workspace.mode == .unlock || workspace.mode == .setup {
                SecureField("PIN", text: $workspace.pin).onSubmit { submit() }
                if workspace.mode == .setup { SecureField("Повторите PIN", text: $workspace.confirmation).onSubmit { submit() } }
                Button(workspace.mode == .setup ? "Сохранить PIN и открыть" : "Открыть") { submit() }.keyboardShortcut(.defaultAction).disabled(workspace.busy)
                if workspace.mode == .unlock {
                    Button("Touch ID или пароль Mac…") { Task { await workspace.systemUnlock(authenticator: authenticator, access: access, coordinator: coordinator) } }.disabled(workspace.busy)
                    Toggle("Автоматически предлагать Touch ID", isOn: $workspace.biometricEnabled).onChange(of: workspace.biometricEnabled) { _, value in if let userID = coordinator.session?.user.id { authenticator.setBiometricEnabled(value, userID: userID) } }
                }
            } else {
                Text("Восстановление PIN через почту текущей учётной записи.").foregroundStyle(.secondary)
                if workspace.mode == .code { TextField("Код из письма", text: $workspace.code) }
                Button(workspace.mode == .code ? "Подтвердить код" : "Получить код") { Task { await workspace.recover(authenticator: authenticator, coordinator: coordinator) } }.disabled(workspace.busy)
            }
            if workspace.mode != .recovery && workspace.mode != .code {
                Button("Восстановить PIN через почту") { workspace.mode = .recovery; workspace.pin = ""; workspace.confirmation = ""; workspace.error = nil }.disabled(workspace.busy)
            }
            if workspace.busy { ProgressView().controlSize(.small) }
            if let error = workspace.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = workspace.notice { Text(notice).foregroundStyle(.secondary) }
        }.textFieldStyle(.roundedBorder).frame(width: 370).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Выплаты").font(.headline)
                Spacer()
                Toggle("Скрывать суммы", isOn: $workspace.hidesAmounts).toggleStyle(.checkbox)
                Button("Добавить…") { edit(nil) }.disabled(repository.isSaving || repository.requiresRefresh)
                Button { if let grant = workspace.grant { Task { try? await repository.load(grant: grant, force: true) } } } label: { Image(systemName: "arrow.clockwise") }.help("Обновить зарплату").disabled(repository.isLoading || repository.isSaving)
                Button { workspace.lock(access: access, authenticator: authenticator); workspace.prepare(authenticator: authenticator, coordinator: coordinator) } label: { Image(systemName: "lock") }.help("Закрыть доступ к зарплате")
            }.padding(12)
            Divider()
            HSplitView {
                List(months, selection: $workspace.month) { month in
                    VStack(alignment: .leading, spacing: 4) { Text(GsmFuelFormatting.monthLabel(month.month)); Text("\(month.entries.count) выплат · " + money(month.total)).font(.caption).foregroundStyle(.secondary) }.tag(month.month)
                }.frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
                VStack(alignment: .leading, spacing: 12) {
                    HStack { LabeledContent("За выбранный месяц", value: money(selectedMonth?.total ?? 0)); Spacer(); LabeledContent("За всё время", value: money(months.reduce(0) { $0 + $1.total })) }
                    if !workspace.hidesAmounts {
                        Chart(Array(months.prefix(12).reversed())) { month in BarMark(x: .value("Месяц", month.month), y: .value("Выплачено, ₽", month.total)) }.frame(height: 130).accessibilityLabel("Выплаты по месяцам")
                    }
                    Table((selectedMonth?.entries ?? []).map { SalaryTableRow(entry: $0) }, selection: $workspace.selection) {
                        TableColumn("Дата") { Text($0.entry.date) }.width(100)
                        TableColumn("Выплата") { Text($0.entry.paymentKind.title) }.width(min: 120, ideal: 150)
                        TableColumn("На руки, ₽") { Text(money(SalaryCalculations.payout(for: $0.entry))) }.width(120)
                        TableColumn("Комментарий") { Text($0.entry.comment ?? "") }
                    }.contextMenu(forSelectionType: String.self) { ids in
                        if let entry = selectedMonth?.entries.first(where: { ids.contains($0.stableID) }) {
                            Button("Изменить…") { edit(entry) }.disabled(repository.isSaving || repository.requiresRefresh)
                            Button("Удалить…", role: .destructive) { pendingDelete = entry }.disabled(repository.isSaving || repository.requiresRefresh || entry.id == nil)
                        }
                    } primaryAction: { ids in if let entry = selectedMonth?.entries.first(where: { ids.contains($0.stableID) }) { edit(entry) } }
                    .overlay { if (selectedMonth?.entries ?? []).isEmpty { if repository.isLoading { ProgressView("Загрузка выплат…") } else { ContentUnavailableView("Нет выплат", systemImage: "banknote") } } }
                    HStack { Button("Изменить…") { if let entry = selectedMonth?.entries.first(where: { $0.stableID == workspace.selection }) { edit(entry) } }.disabled(workspace.selection == nil || repository.isSaving || repository.requiresRefresh); Spacer(); Text("\(selectedMonth?.entries.count ?? 0) выплат").foregroundStyle(.secondary) }
                }.padding(14).frame(minWidth: 560)
            }
            if repository.connection == .offline { Label("Локальные данные зарплаты", systemImage: "wifi.slash").foregroundStyle(.secondary).padding(10) }
            if let error = workspace.error ?? repository.error ?? repository.cacheWarning { Text(error).foregroundStyle(.red).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            if let notice = workspace.notice { Text(notice).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
    private func money(_ value: Double) -> String { workspace.hidesAmounts ? "Сумма скрыта" : GsmFuelFormatting.number(value) + " ₽" }
    private func submit() { workspace.submitPIN(authenticator: authenticator, access: access, coordinator: coordinator) }
    private func reconcile() { if !months.contains(where: { $0.month == workspace.month }) { workspace.month = months.first?.month }; if !(selectedMonth?.entries.contains(where: { $0.stableID == workspace.selection }) ?? false) { workspace.selection = nil } }
    private func edit(_ base: SalaryEntry?) { guard !repository.isSaving, !repository.requiresRefresh, let context = coordinator.context, let grant = workspace.grant, access.accepts(grant) else { return }; workspace.editor = MacSalaryEditorModel(base: base, context: context, grant: grant) }
    private func remove(_ base: SalaryEntry, grant: SalaryAccessGrant) { Task { do { try await repository.delete(base, grant: grant); if access.accepts(grant) { workspace.selection = nil; workspace.notice = "Выплата удалена." } } catch { if access.accepts(grant), !AppErrorClassification.isCancellation(error) { workspace.error = repository.error ?? error.localizedDescription } } } }
}

struct MacSalaryEditor: View {
    @Bindable var model: MacSalaryEditorModel
    let repository: SalaryRepository
    let access: SalaryAccess
    let coordinator: EngineerApplicationCoordinator
    let completion: (SalaryEntry?) -> Void
    @State private var confirmsDiscard = false
    private var validation: String? { do { _ = try model.entry(); return nil } catch { return error.localizedDescription } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.base == nil ? "Добавить выплату" : "Изменить выплату").font(.title2)
            Form {
                DatePicker("Дата выплаты", selection: $model.date, displayedComponents: .date)
                TextField("Месяц начисления (YYYY-MM)", text: $model.period)
                if model.usesNetAmount {
                    TextField("На руки, ₽", text: $model.amount)
                } else {
                    TextField("Оклад, ₽", text: $model.baseSalary); TextField("Работа в выходной, ₽", text: $model.weekendPay)
                    Text("Исторические выплаты до 13 мая 2026: НДФЛ 13% с округлением вниз.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Вид выплаты", selection: $model.kind) { ForEach(SalaryPaymentKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                TextField("Комментарий", text: $model.comment, axis: .vertical).lineLimit(3...6)
            }.disabled(model.isSaving)
            if let error = model.error ?? validation { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Отмена") { if model.isDirty { confirmsDiscard = true } else { completion(nil) } }.keyboardShortcut(.cancelAction).disabled(model.isSaving)
                Spacer()
                if repository.requiresRefresh { Button("Обновить") { Task { try? await repository.load(grant: model.grant, force: true) } }.disabled(repository.isSaving || repository.isLoading) }
                if model.isSaving { ProgressView().controlSize(.small) }
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction).disabled(model.isSaving || repository.isSaving || repository.requiresRefresh || validation != nil || !access.accepts(model.grant))
            }
        }.padding(20).frame(width: 520).interactiveDismissDisabled(model.isDirty || model.isSaving)
        .confirmationDialog("Отбросить изменения выплаты?", isPresented: $confirmsDiscard) { Button("Отбросить", role: .destructive) { completion(nil) } }
        .onChange(of: model.date) { old, new in if model.base == nil, model.period == SalaryEntry.inferredPeriodMonth(for: MacRouteDate.key(old)) { model.period = SalaryEntry.inferredPeriodMonth(for: MacRouteDate.key(new)) } }
    }
    private func save() {
        guard !model.isSaving, access.accepts(model.grant), coordinator.accepts(model.context) else { return }
        model.isSaving = true; model.error = nil
        Task {
            defer { model.isSaving = false }
            do { let saved = try await repository.save(model.entry(), base: model.base, grant: model.grant); guard access.accepts(model.grant), coordinator.accepts(model.context) else { return }; completion(saved) }
            catch { if access.accepts(model.grant), coordinator.accepts(model.context), !AppErrorClassification.isCancellation(error) { model.error = repository.error ?? error.localizedDescription } }
        }
    }
}
