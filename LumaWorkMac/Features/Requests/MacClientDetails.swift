import SwiftUI
import EngineerCore

struct MacCompanySelection: Identifiable { let id: String }

struct MacClientDetails: View {
    let record: SimpleOneRequestRecord
    let repository: ClientDetailsRepository
    let coordinator: EngineerApplicationCoordinator
    @Bindable var workspace: MacRequestsWorkspace
    private var comment: ClientPersonalComment? { repository.selected(tin: record.merchantTIN, address: record.address, terminalID: record.terminalID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if !record.merchantTIN.isEmpty {
                HStack {
                    Text("ИНН: " + record.merchantTIN)
                    Button("Организация…") { workspace.company = MacCompanySelection(id: record.merchantTIN) }
                }
            }
            HStack {
                Text("Личный комментарий").font(.headline)
                Spacer()
                if repository.isLoading { ProgressView().controlSize(.small) }
                Button { Task { try? await repository.load(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Обновить комментарии").disabled(repository.isLoading || repository.isSaving)
            }
            if let comment {
                if !comment.contactPerson.isEmpty { Text(comment.contactPerson) }
                if !comment.phone.isEmpty { Text(ClientPersonalCommentPhoneFormatter.display(comment.phone)) }
                if !comment.email.isEmpty { Text(comment.email) }
                if let info = comment.extraInfo, !info.isEmpty { Text(info) }
                Text(comment.targets.isEmpty ? "Все адреса этого ИНН" : comment.targets.map(\.displayText).joined(separator: "; ")).font(.caption).foregroundStyle(.secondary)
                if let author = comment.authorShortName { Text("\(author) · \(comment.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                Button("Изменить…") { edit(comment) }.disabled(repository.isSaving || repository.requiresRefresh)
                if comment.targets.isEmpty, !record.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Отдельный комментарий для этого адреса…") { edit(comment, split: true) }.disabled(repository.isSaving || repository.requiresRefresh)
                }
            } else if repository.hasSnapshot {
                Text("Комментария нет").foregroundStyle(.secondary)
                Button("Добавить…") { edit(nil) }.disabled(record.merchantTIN.isEmpty || repository.isSaving || repository.requiresRefresh)
                if record.merchantTIN.isEmpty { Text("Для создания комментария нужен ИНН.").font(.caption).foregroundStyle(.secondary) }
            } else if !repository.isLoading { Text("Комментарии ещё не загружены").foregroundStyle(.secondary) }
            if let error = repository.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            if let warning = repository.cacheWarning { Text(warning).font(.caption).foregroundStyle(.secondary) }
        }.task(id: coordinator.context) { try? await repository.load() }
    }
    private func edit(_ comment: ClientPersonalComment?, split: Bool = false) {
        guard let context = coordinator.context else { return }
        var draft = comment.map { ClientPersonalCommentDraft(comment: $0, fallbackTIN: record.merchantTIN) } ?? ClientPersonalCommentDraft()
        if comment == nil {
            draft.tin = record.merchantTIN
            if !record.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.targets = [.init(address: record.address)] }
            if !record.terminalID.isEmpty { draft.terminalIDs = [record.terminalID] }
        }
        if let comment, !split, comment.targets.contains(where: { $0.normalizedKey == ClientPersonalCommentMatchingIndex.normalizedAddress(record.address) }),
           !record.terminalID.isEmpty, !draft.terminalIDs.contains(where: { ClientPersonalCommentMatchingIndex.normalizedTerminalID($0) == ClientPersonalCommentMatchingIndex.normalizedTerminalID(record.terminalID) }) {
            draft.terminalIDs.append(record.terminalID)
        }
        if split, let comment {
            draft.serverID = nil; draft.sourceCommentID = comment.id; draft.targets = [.init(address: record.address)]
            let current = ClientPersonalCommentMatchingIndex.normalizedTerminalID(record.terminalID)
            draft.terminalIDs = comment.terminalIDs.filter { ClientPersonalCommentMatchingIndex.normalizedTerminalID($0) == current }
        }
        workspace.clientContext = context; workspace.clientBaseline = draft; workspace.clientDraft = draft
    }
}

struct MacClientCommentEditor: View {
    @Bindable var workspace: MacRequestsWorkspace
    let repository: ClientDetailsRepository
    @State var draft: ClientPersonalCommentDraft
    @State private var addresses: String
    @State private var terminals: String
    @State private var saveError: String?
    @State private var isSaving = false
    init(workspace: MacRequestsWorkspace, repository: ClientDetailsRepository, draft: ClientPersonalCommentDraft) {
        self.workspace = workspace; self.repository = repository; _draft = State(initialValue: draft)
        _addresses = State(initialValue: draft.targets.map(\.address).joined(separator: "\n"))
        _terminals = State(initialValue: draft.terminalIDs.joined(separator: "\n"))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Личный комментарий").font(.title2)
            Form {
                TextField("ИНН", text: $draft.tin).disabled(draft.serverID != nil || draft.sourceCommentID != nil)
                TextField("Контактное лицо", text: $draft.contactPerson)
                TextField("Телефон", text: $draft.phone)
                TextField("Email", text: $draft.email)
                TextField("Дополнительная информация", text: $draft.extraInfo, axis: .vertical).lineLimit(3...6)
                LabeledContent("Адреса") { TextEditor(text: $addresses).frame(height: 80).border(.separator) }
                Text("Один адрес в строке. Пустой список — все адреса этого ИНН.").font(.caption).foregroundStyle(.secondary)
                LabeledContent("ID терминалов") { TextEditor(text: $terminals).frame(height: 65).border(.separator) }
                Text("Один ID в строке.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = saveError ?? repository.error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Обновить комментарии") { Task { try? await repository.load(force: true) } }.disabled(isSaving || repository.isLoading)
                Spacer()
                Button("Отмена") { workspace.discardClientDraft() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave || isSaving || repository.isSaving || repository.requiresRefresh || draft.extraInfo.count > 1000 || draft.targets.count > 100 || draft.targets.contains { $0.address.count > 300 } || draft.terminalIDs.count > 200 || draft.terminalIDs.contains { $0.count > 120 })
            }
        }.padding(20).frame(width: 620)
        .interactiveDismissDisabled()
        .onChange(of: addresses) { _, text in draft.targets = lines(text).map { .init(address: $0) } }
        .onChange(of: terminals) { _, text in draft.terminalIDs = lines(text) }
        .onChange(of: draft) { _, value in workspace.clientDraft = value }
    }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private func save() {
        guard let context = workspace.clientContext else { return }
        let id = draft.id, value = draft
        isSaving = true; saveError = nil
        Task {
            do {
                try await repository.save(value, expectedContext: context)
                guard workspace.clientContext == context, workspace.clientDraft?.id == id else { return }
                workspace.discardClientDraft()
            } catch {
                guard workspace.clientContext == context, workspace.clientDraft?.id == id else { return }
                if !AppErrorClassification.isCancellation(error) { saveError = repository.error ?? error.localizedDescription }
            }
            isSaving = false
        }
    }
}

struct MacCompanySheet: View {
    let tin: String
    let repository: ClientDetailsRepository
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Данные по ИНН").font(.title2)
                Spacer()
                if repository.loadingCompanies.contains(tin) { ProgressView().controlSize(.small) }
                Button("Обновить") { Task { try? await repository.loadCompany(tin, force: true) } }.disabled(repository.loadingCompanies.contains(tin))
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let company = repository.company(tin) {
                        Text(company.name).font(.headline)
                        field("Полное наименование", company.fullName)
                        field("Статус", company.status.map(status))
                        field("ИНН", company.inn); field("КПП", company.kpp); field("ОГРН", company.ogrn)
                        field("Форма", company.legalForm); field("Руководитель", company.directorName); field("Должность", company.directorPost)
                        field("Юридический адрес", company.address); field("ОКВЭД", company.okved); field("Деятельность", company.okvedName)
                        field("Регистрация", company.registrationDate.flatMap { ISO8601DateFormatter().date(from: $0) }.map { $0.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU"))) })
                    } else if repository.loadingCompanies.contains(tin) { Text("Загрузка организации…").foregroundStyle(.secondary) }
                    if let error = repository.companyErrors[tin] { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
        }.padding(20).frame(width: 600, height: 560).task { try? await repository.loadCompany(tin) }
    }
    @ViewBuilder private func field(_ title: String, _ text: String?) -> some View {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.caption).foregroundStyle(.secondary); Text(text) }
        }
    }
    private func status(_ raw: String) -> String {
        switch raw.uppercased() {
        case "ACTIVE": "Действующая"; case "LIQUIDATING": "Ликвидируется"; case "LIQUIDATED": "Ликвидирована"
        case "BANKRUPT": "Банкротство"; case "REORGANIZING": "Реорганизация"; default: raw
        }
    }
}
