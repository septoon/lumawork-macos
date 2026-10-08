import Foundation
import CryptoKit

public struct RouteMapPlan: Hashable, Sendable {
    public let addresses: [String]
    public let coordinateOverrides: [AppleRouteCoordinate?]
    public init(addresses: [String], coordinateOverrides: [AppleRouteCoordinate?] = []) {
        self.addresses = addresses.map { $0.normalizedAddressCommaSpacing() }
        self.coordinateOverrides = addresses.indices.map { i in
            guard coordinateOverrides.indices.contains(i), let value = coordinateOverrides[i], value.isValid else { return nil }
            return value
        }
    }
    public init(stops: [RouteStop], remembered: [String: AppleRouteCoordinate] = [:]) {
        self.init(addresses: stops.map(\.address), coordinateOverrides: stops.map { $0.coordinateOverride ?? remembered[$0.address.routeCoordinateKey] })
    }
    public var isEmpty: Bool { addresses.count < 3 || addresses.dropFirst().dropLast().allSatisfy(\.isEmpty) }
    public var isComplete: Bool { !isEmpty && addresses.allSatisfy { !$0.isEmpty } }
    var storageKey: String {
        struct Identity: Encodable { let addresses: [String]; let overrides: [AppleRouteCoordinate?] }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try! encoder.encode(Identity(addresses: addresses, overrides: coordinateOverrides))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
public struct RouteMapCandidate: Sendable {
    public let coordinate: AppleRouteCoordinate
    public let address: String
    public init(coordinate: AppleRouteCoordinate, address: String) { self.coordinate = coordinate; self.address = address }
}
public struct RouteMapLeg: Codable, Hashable, Sendable {
    public let distanceMeters: Double
    public let coordinates: [AppleRouteCoordinate]
    public init(distanceMeters: Double, coordinates: [AppleRouteCoordinate]) { self.distanceMeters = distanceMeters; self.coordinates = coordinates }
}
public struct RouteMapSnapshot: Codable, Hashable, Sendable {
    public static let currentGeocodingVersion = 4
    public let addresses: [String]
    public let distanceKm: Int
    public let stopCoordinates: [AppleRouteCoordinate]
    public let legs: [RouteMapLeg]
    public let coordinateOverrides: [AppleRouteCoordinate?]
    public let unverifiedStopIndices: [Int]
    public let routingIncomplete: Bool
    public let failedLegIndex: Int?
    public var geocodingVersion: Int
    public init(plan: RouteMapPlan, distanceKm: Int, stopCoordinates: [AppleRouteCoordinate] = [], legs: [RouteMapLeg] = [], unverified: [Int] = [], failedLegIndex: Int? = nil) {
        addresses = plan.addresses; coordinateOverrides = plan.coordinateOverrides; self.distanceKm = distanceKm
        self.stopCoordinates = stopCoordinates; self.legs = legs; unverifiedStopIndices = unverified
        routingIncomplete = failedLegIndex != nil; self.failedLegIndex = failedLegIndex; geocodingVersion = Self.currentGeocodingVersion
    }
    public var hasGeometry: Bool { !stopCoordinates.isEmpty && stopCoordinates.count == addresses.count && stopCoordinates.allSatisfy(\.isValid) }
    public var canApplyDistance: Bool { hasGeometry && !routingIncomplete && unverifiedStopIndices.isEmpty && distanceKm >= 0 && legs.count == addresses.count - 1 }
    public func matches(_ plan: RouteMapPlan) -> Bool { geocodingVersion == Self.currentGeocodingVersion && addresses == plan.addresses && coordinateOverrides == plan.coordinateOverrides }
    public var failureDescription: String? {
        guard routingIncomplete else { return nil }
        if let i = failedLegIndex, i >= 0, i + 1 < addresses.count { return "Apple Maps не удалось построить автомобильный маршрут между точками «\(addresses[i])» и «\(addresses[i+1])»." }
        return RouteMapError.directionsUnavailable.localizedDescription
    }
}
public enum RouteMapError: LocalizedError {
    case incompleteRoute, directionsUnavailable
    case addressNotFound(String), geocodingFailed(String)
    public var errorDescription: String? {
        switch self {
        case .incompleteRoute: "Заполните адреса всех точек маршрута."
        case .directionsUnavailable: "Apple Maps не удалось построить автомобильный маршрут."
        case .addressNotFound(let address): "Apple Maps не нашёл адрес: \(address)."
        case .geocodingFailed(let address): "Apple Maps не удалось определить положение точки: \(address). Повторите расчёт или уточните адрес."
        }
    }
}
@MainActor public protocol RouteMapTransport {
    func geocode(_ query: String) async throws -> [RouteMapCandidate]
    func search(_ query: String, near: AppleRouteCoordinate?) async throws -> [RouteMapCandidate]
    func leg(from: AppleRouteCoordinate, to: AppleRouteCoordinate) async throws -> RouteMapLeg
}
@MainActor public protocol RouteMapServing { func route(for plan: RouteMapPlan, force: Bool) async throws -> RouteMapSnapshot }
@MainActor public final class RouteMapCalculator: RouteMapServing {
    private struct Resolved { let coordinate: AppleRouteCoordinate; let verified: Bool }
    private struct LegKey: Hashable { let from: AppleRouteCoordinate; let to: AppleRouteCoordinate }
    private let transport: any RouteMapTransport
    private var points: [String: Resolved] = [:]
    private var legs: [LegKey: RouteMapLeg] = [:]
    public init(transport: any RouteMapTransport) { self.transport = transport }
    public func route(for plan: RouteMapPlan, force: Bool = false) async throws -> RouteMapSnapshot {
        try Task.checkCancellation()
        if force { points = [:]; legs = [:] }
        guard !plan.isEmpty else { return RouteMapSnapshot(plan: plan, distanceKm: 0) }
        guard plan.isComplete else { throw RouteMapError.incompleteRoute }
        var coordinates: [AppleRouteCoordinate] = []; var unverified = Set<Int>()
        for i in plan.addresses.indices {
            try Task.checkCancellation()
            if let override = plan.coordinateOverrides[i] { coordinates.append(override) }
            else {
                let found = try await point(for: plan.addresses[i])
                coordinates.append(found.coordinate)
                if !found.verified { unverified.insert(i) }
            }
        }
        for i in coordinates.indices where plan.coordinateOverrides[i] == nil {
            if coordinates.indices.contains(where: { j in j != i && plan.addresses[j].routeCoordinateKey != plan.addresses[i].routeCoordinateKey && coordinates[i].meters(to: coordinates[j]) < 10 }) { unverified.insert(i) }
        }
        var geometry: [RouteMapLeg] = []; var meters = 0.0
        for i in 0..<(coordinates.count - 1) {
            do {
                let key = LegKey(from: coordinates[i], to: coordinates[i+1])
                let value: RouteMapLeg
                if let cached = legs[key] { value = cached }
                else if key.from == key.to { value = RouteMapLeg(distanceMeters: 0, coordinates: [key.from]) }
                else { value = try await transport.leg(from: key.from, to: key.to) }
                try Task.checkCancellation()
                guard value.distanceMeters.isFinite, value.distanceMeters >= 0, value.coordinates.allSatisfy(\.isValid) else { throw RouteMapError.directionsUnavailable }
                legs[key] = value; geometry.append(value); meters += value.distanceMeters
            } catch {
                try Task.checkCancellation()
                if AppErrorClassification.isCancellation(error) { throw CancellationError() }
                return RouteMapSnapshot(plan: plan, distanceKm: 0, stopCoordinates: coordinates, unverified: unverified.sorted(), failedLegIndex: i)
            }
        }
        try Task.checkCancellation()
        let km = ceil(meters / 1000)
        guard km.isFinite, km < Double(Int.max) else { throw RouteMapError.directionsUnavailable }
        return RouteMapSnapshot(plan: plan, distanceKm: Int(km), stopCoordinates: coordinates, legs: geometry, unverified: unverified.sorted())
    }
    private func point(for address: String) async throws -> Resolved {
        let query = address.qualifiedAppleRouteAddress()
        if let cached = points[query] { return cached }
        var candidates: [RouteMapCandidate]
        do { candidates = try await transport.geocode(query).filter { $0.coordinate.isValid } }
        catch {
            try Task.checkCancellation()
            if AppErrorClassification.isCancellation(error) { throw CancellationError() }
            throw RouteMapError.geocodingFailed(address)
        }
        var searchQuery = query
        if candidates.isEmpty, let fallback = address.appleRouteStreetFallbackAddress() {
            do {
                candidates = try await transport.geocode(fallback).filter { $0.coordinate.isValid && RouteMapAddressValidation.matchesStreet(query: query, found: $0.address) }
                searchQuery = fallback
            } catch {
                try Task.checkCancellation()
                if AppErrorClassification.isCancellation(error) { throw CancellationError() }
                throw RouteMapError.geocodingFailed(address)
            }
        }
        try Task.checkCancellation()
        var verified = candidates.filter { RouteMapAddressValidation.matches(query: query, found: $0.address) }
        if verified.count != 1 {
            do {
                let found = try await transport.search(searchQuery, near: candidates.first?.coordinate).filter {
                    $0.coordinate.isValid && (searchQuery == query || RouteMapAddressValidation.matchesStreet(query: query, found: $0.address))
                }
                try Task.checkCancellation()
                let matches = found.filter { RouteMapAddressValidation.matches(query: query, found: $0.address) }
                if matches.count == 1 { verified = matches }
                if candidates.isEmpty { candidates = found }
            } catch {
                try Task.checkCancellation()
                if AppErrorClassification.isCancellation(error) { throw CancellationError() }
            }
        }
        guard let chosen = verified.count == 1 ? verified.first : candidates.first else { throw RouteMapError.addressNotFound(address) }
        let result = Resolved(coordinate: chosen.coordinate, verified: verified.count == 1)
        points[query] = result; return result
    }
}
private extension AppleRouteCoordinate {
    func meters(to other: Self) -> Double {
        let radians = Double.pi / 180
        let lat = (other.latitude-latitude)*radians; let lon = (other.longitude-longitude)*radians
        let a = pow(sin(lat/2),2) + cos(latitude*radians)*cos(other.latitude*radians)*pow(sin(lon/2),2)
        return 6_371_000 * 2 * asin(sqrt(min(1,max(0,a))))
    }
}
