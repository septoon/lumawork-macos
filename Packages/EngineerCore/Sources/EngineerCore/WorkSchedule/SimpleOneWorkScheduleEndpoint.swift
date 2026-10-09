import Foundation

struct WorkScheduleWidgetLoadRequest {
    let url: URL
    let method: String
    let body: [String: Any]
}

enum WorkScheduleEndpointError: Error {
    case invalidURL
}

struct SimpleOneWorkScheduleEndpoint {
    let baseURL: URL

    func journals(page: Int, perPage: Int) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("list/itsm_tchnsrv_accounting_journal"),
            resolvingAgainstBaseURL: false
        ) else {
            throw WorkScheduleEndpointError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage))
        ]
        guard let url = components.url else {
            throw WorkScheduleEndpointError.invalidURL
        }
        return url
    }

    func record(sysID: String) -> URL {
        baseURL
            .appendingPathComponent("record")
            .appendingPathComponent("itsm_tchnsrv_accounting_journal")
            .appendingPathComponent(sysID)
    }

    func widgetLoad(
        widgetInstanceID: String,
        recordID: String
    ) throws -> WorkScheduleWidgetLoadRequest {
        guard !widgetInstanceID.isEmpty, !recordID.isEmpty else {
            throw WorkScheduleEndpointError.invalidURL
        }
        return WorkScheduleWidgetLoadRequest(
            url: baseURL
                .appendingPathComponent("widget/run-server-script")
                .appendingPathComponent(widgetInstanceID),
            method: "POST",
            body: [
                "recordID": recordID,
                "action": "load"
            ]
        )
    }
}
