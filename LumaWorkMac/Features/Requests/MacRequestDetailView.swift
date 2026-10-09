import SwiftUI
import EngineerCore

struct MacRequestDetailView: View {
    let record: SimpleOneRequestRecord
    let isLoading: Bool
    let error: String?
    let refresh: () -> Void
    let openBrowser: () -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(record.number).font(.title2).fontWeight(.semibold)
                    Spacer()
                    if isLoading { ProgressView().controlSize(.small) }
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }.help("Обновить карточку").disabled(isLoading)
                }
                Button("Открыть в SimpleOne…", action: openBrowser).disabled(record.sysID.isEmpty)
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                value("Входящий номер", record.incomingNumber)
                value("Краткое описание", record.shortDescription)
                value("Тип", RequestsPolicy.typeTitle(record.requestType))
                value("Статус", record.state)
                if let sla = record.slaStatusText, record.source == .active { Text(sla).foregroundStyle(record.isOverdue ? .red : .secondary) }
                value("Исполнитель", record.assignedUser)
                value("Рабочая группа", record.assignmentGroup)
                value("Регистрация", record.registeredAt ?? "")
                value("Предельный срок", record.deadline)
                if record.source == .closed { value(RequestsPolicy.isReturnEquipment(record.requestType) ? "Время регистрации" : "Выполнена", RequestsPolicy.effectiveTime(record)) }
                Divider()
                value("Заказчик", record.customer)
                value("Адрес", record.address)
                value("Контакт", record.contactPerson)
                value("Телефон", record.contactPhone ?? "")
                value("ID терминала", record.terminalID)
                value("Модель", record.terminalModel)
                value("Комментарий инженера", record.engineerComment)
                value("Код закрытия", record.closureCode ?? "")
                value("Решение", record.resolution ?? "")
                value("Информация", record.informationText)
                if let fields = record.tableFields {
                    DisclosureGroup("Все поля заявки") {
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in value(field.key, field.value) }
                    }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }
    @ViewBuilder private func value(_ label: String, _ value: String) -> some View {
        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 3) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}
