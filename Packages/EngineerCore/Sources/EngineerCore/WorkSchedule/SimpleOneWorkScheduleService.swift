import Foundation

extension SimpleOneRequestsService {
    public func fetchWorkScheduleJournals(
        authKey: String,
        perPage: Int = 100
    ) async throws -> [WorkScheduleJournal] {
        var page = 1
        var journals: [WorkScheduleJournal] = []
        var seenIDs = Set<String>()

        while true {
            let url: URL
            do {
                url = try SimpleOneWorkScheduleEndpoint(baseURL: baseURL).journals(page: page, perPage: perPage)
            } catch {
                throw SimpleOneServiceError.invalidURL
            }
            let response = try await request(url: url, authKey: authKey)
            let pageJournals = try SimpleOneWorkScheduleParser.journals(from: response)
            let previousCount = journals.count
            for journal in pageJournals where seenIDs.insert(journal.sysID).inserted {
                journals.append(journal)
            }

            let total = totalCount( response)
            let hasMore = total.map { page * perPage < $0 }
                ?? (pageJournals.count == perPage)
            guard hasMore else { break }
            guard journals.count > previousCount else { throw SimpleOneServiceError.invalidResponse }
            page += 1
        }

        return journals.sorted {
            if $0.cityName != $1.cityName {
                return $0.cityName.localizedStandardCompare($1.cityName) == .orderedAscending
            }
            if $0.year != $1.year { return $0.year > $1.year }
            return $0.month > $1.month
        }
    }

    public func fetchWorkSchedule(
        journal: WorkScheduleJournal,
        authKey: String
    ) async throws -> WorkSchedule {
        let recordResponse = try await request(
            url: SimpleOneWorkScheduleEndpoint(baseURL: baseURL).record(sysID: journal.sysID),
            authKey: authKey
        )
        let auditInfo = SimpleOneWorkScheduleParser.auditInfo(from: recordResponse)
        let widgetID = try SimpleOneWorkScheduleParser.widgetInstanceID(from: recordResponse)
        let loadRequest: WorkScheduleWidgetLoadRequest
        do {
            loadRequest = try SimpleOneWorkScheduleEndpoint(baseURL: baseURL).widgetLoad(
                widgetInstanceID: widgetID,
                recordID: journal.sysID
            )
        } catch {
            throw SimpleOneServiceError.invalidURL
        }
        let scheduleResponse = try await request(
            url: loadRequest.url,
            method: loadRequest.method,
            body: loadRequest.body,
            authKey: authKey
        )
        return try SimpleOneWorkScheduleParser.schedule(
            from: scheduleResponse,
            journal: journal,
            auditInfo: auditInfo
        )
    }
}
