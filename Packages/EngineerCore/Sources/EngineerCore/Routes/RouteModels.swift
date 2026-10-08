import Foundation

public struct RouteStop: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var address: String {
        didSet {
            if address.routeCoordinateKey != oldValue.routeCoordinateKey { coordinateOverride = nil }
        }
    }
    public var org: String
    public var tid: String
    public var reason: String
    public var status: RouteStopStatus
    public var declineReason: String
    public var requestNumber: String
    public var coordinateOverride: AppleRouteCoordinate? = nil

    public init(id: String = UUID().uuidString, address: String = "", org: String = "", tid: String = "", reason: String = "", status: RouteStopStatus = .pending, declineReason: String = "", requestNumber: String = "", coordinateOverride: AppleRouteCoordinate? = nil) {
        self.id = id; self.address = address; self.org = org; self.tid = tid; self.reason = reason
        self.status = status; self.declineReason = declineReason; self.requestNumber = requestNumber
        self.coordinateOverride = coordinateOverride
    }
}

public struct RouteDayRecord: Codable, Hashable, Sendable {
    public var date: String
    public var workType: RouteWorkType
    public var stops: [RouteStop]
    public var distanceKm: Int?
    public var periodStartOdometer: Int?
    public var reportedDistanceKm: Double? = nil
    public var routeSummary: String? = nil
    public var requestNumbersSummary: String? = nil
    public var reportedPeriodStartOdometer: Int? = nil
    public var fuelDate: String? = nil
    public var fuelLiters: Double? = nil
    public var fuelCostRub: Double? = nil
    public var sent: Bool

    public init(
        date: String,
        workType: RouteWorkType = .pos,
        stops: [RouteStop],
        distanceKm: Int? = nil,
        periodStartOdometer: Int? = nil,
        reportedDistanceKm: Double? = nil,
        routeSummary: String? = nil,
        requestNumbersSummary: String? = nil,
        reportedPeriodStartOdometer: Int? = nil,
        fuelDate: String? = nil,
        fuelLiters: Double? = nil,
        fuelCostRub: Double? = nil,
        sent: Bool
    ) {
        self.date = date
        self.workType = workType
        self.stops = stops
        self.distanceKm = distanceKm
        self.periodStartOdometer = periodStartOdometer
        self.reportedDistanceKm = reportedDistanceKm
        self.routeSummary = routeSummary
        self.requestNumbersSummary = requestNumbersSummary
        self.reportedPeriodStartOdometer = reportedPeriodStartOdometer
        self.fuelDate = fuelDate
        self.fuelLiters = fuelLiters
        self.fuelCostRub = fuelCostRub
        self.sent = sent
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case workType
        case stops
        case distanceKm
        case periodStartOdometer
        case reportedDistanceKm
        case routeSummary
        case requestNumbersSummary
        case reportedPeriodStartOdometer
        case fuelDate
        case fuelLiters
        case fuelCostRub
        case sent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        workType = try container.decodeIfPresent(RouteWorkType.self, forKey: .workType) ?? .pos
        stops = try container.decodeIfPresent([RouteStop].self, forKey: .stops) ?? []
        distanceKm = try container.decodeIfPresent(Int.self, forKey: .distanceKm)
        periodStartOdometer = try container.decodeIfPresent(Int.self, forKey: .periodStartOdometer)
        reportedDistanceKm = try container.decodeIfPresent(Double.self, forKey: .reportedDistanceKm)
        routeSummary = try container.decodeIfPresent(String.self, forKey: .routeSummary)
        requestNumbersSummary = try container.decodeIfPresent(String.self, forKey: .requestNumbersSummary)
        reportedPeriodStartOdometer = try container.decodeIfPresent(Int.self, forKey: .reportedPeriodStartOdometer)
        fuelDate = try container.decodeIfPresent(String.self, forKey: .fuelDate)
        fuelLiters = try container.decodeIfPresent(Double.self, forKey: .fuelLiters)
        fuelCostRub = try container.decodeIfPresent(Double.self, forKey: .fuelCostRub)
        sent = try container.decodeIfPresent(Bool.self, forKey: .sent) ?? false
    }
}

public struct AppleRouteCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}

public struct RouteDayKey: Codable, Hashable, Sendable {
    public let date: String
    public let workType: RouteWorkType
    public init(date: String, workType: RouteWorkType) { self.date = date; self.workType = workType }
    public var storageKey: String { workType.storageKey(for: date) }
}

extension RouteDayRecord {
    public var key: RouteDayKey { RouteDayKey(date: date, workType: workType) }
}

public struct RouteSettings: Codable, Hashable, Sendable {
    public var warehouseAddress: String
    public var homeAddress: String
    public static let officeAddress = "Алушта, ул. В. Хромых, 11"
    public static let `default` = RouteSettings(warehouseAddress: officeAddress)
    public init(warehouseAddress: String, homeAddress: String = "") { self.warehouseAddress = warehouseAddress; self.homeAddress = homeAddress }
    public var startAddress: String { let value = warehouseAddress.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? Self.officeAddress : value }
    public var endAddress: String { startAddress }
}
