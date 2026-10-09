import Foundation

public struct SalaryService {
    private let client: DomainHTTPClient
    public init(config: AppConfig, token: String) { client = DomainHTTPClient(config: config, token: token) }
    public static func payload(_ entry: SalaryEntry) throws -> [String: Any] {
        guard entry.date.count == 10, RequestsPolicy.date(entry.date) != nil,
              entry.baseSalary.isFinite, entry.baseSalary >= 0, entry.weekendPay.isFinite, entry.weekendPay >= 0,
              (entry.baseSalary + entry.weekendPay).isFinite, entry.amount.map({ $0.isFinite && $0 >= 0 }) ?? true,
              entry.periodMonth.map(GsmWire.isValidMonth) ?? true, (entry.comment?.count ?? 0) <= 5000 else { throw AppServiceError.message("Проверьте дату, месяц начисления и суммы выплаты.") }
        return ["date": entry.date, "baseSalary": entry.baseSalary, "weekendPay": entry.weekendPay,
                "periodMonth": entry.periodMonth as Any? ?? NSNull(), "amount": entry.amount as Any? ?? NSNull(),
                "kind": entry.kind?.rawValue as Any? ?? NSNull(), "comment": entry.comment as Any? ?? NSNull()]
    }
    private func normalize(_ raw: Any) throws -> SalaryEntry {
        guard let row = raw as? [String: Any], let date = row["date"] as? String else { throw GsmFuelError.invalidResponse }
        func number(_ key: String) throws -> Double? {
            guard let raw = row[key], !(raw is NSNull) else { return nil }
            let value = doubleValue(raw)
            guard let value, value.isFinite, value >= 0 else { throw GsmFuelError.invalidResponse }; return value
        }
        let entry = SalaryEntry(id: (row["id"] as? String) ?? (row["_id"] as? String), date: date,
                                baseSalary: try number("baseSalary") ?? 0, weekendPay: try number("weekendPay") ?? 0,
                                periodMonth: (row["periodMonth"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? SalaryEntry.inferredPeriodMonth(for: date),
                                amount: try number("amount"), kind: (row["kind"] as? String).flatMap { SalaryPaymentKind(rawValue: $0.lowercased()) },
                                comment: row["comment"] as? String)
        _ = try Self.payload(entry)
        if let id = entry.id { _ = try DomainHTTPClient.id(id) }
        return entry
    }
    public func entries() async throws -> [SalaryEntry] {
        let json = try await client.request("api/v2/salary")
        let root = json as? [String: Any]
        guard let records = (json as? [Any]) ?? (root?["records"] as? [Any]) ?? (root?["entries"] as? [Any]) ?? (root?["data"] as? [Any]) ?? (root?["items"] as? [Any]) else { throw GsmFuelError.invalidResponse }
        let entries = try records.map(normalize)
        guard Set(entries.map(\.stableID)).count == entries.count else { throw GsmFuelError.invalidResponse }
        return entries
    }
    public func save(_ entry: SalaryEntry) async throws -> SalaryEntry {
        let path = "api/v2/salary" + (try entry.id.map { "/" + (try DomainHTTPClient.id($0)) } ?? "")
        guard let response = try await client.request(path, method: entry.id == nil ? "POST" : "PUT", body: Self.payload(entry)) else { throw GsmFuelError.invalidResponse }
        let saved = try normalize(response)
        guard saved.id != nil, entry.id == nil || entry.id == saved.id else { throw GsmFuelError.invalidResponse }
        return saved
    }
    public func delete(id: String) async throws { _ = try await client.request("api/v2/salary/" + DomainHTTPClient.id(id), method: "DELETE") }
}
