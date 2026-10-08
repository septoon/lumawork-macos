import MapKit
import EngineerCore

@MainActor
final class MacRouteMapTransport: RouteMapTransport {
    func geocode(_ query: String) async throws -> [RouteMapCandidate] {
        if #available(macOS 26.0, *) {
            guard let request = MKGeocodingRequest(addressString: query) else { return [] }
            request.preferredLocale = Locale(identifier: "ru_RU")
            do {
                let items = try await withTaskCancellationHandler { try await request.mapItems } onCancel: { Task { @MainActor in request.cancel() } }
                try Task.checkCancellation()
                return items.map(candidate)
            } catch {
                try Task.checkCancellation()
                let native = error as NSError
                if native.domain == MKErrorDomain, native.code == MKError.Code.placemarkNotFound.rawValue { return [] }
                throw error
            }
        }
        return try await search(query, near: nil)
    }
    func search(_ query: String, near: AppleRouteCoordinate?) async throws -> [RouteMapCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query; request.resultTypes = .address
        if let near { request.region = MKCoordinateRegion(center: near.location, latitudinalMeters: 30_000, longitudinalMeters: 30_000) }
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler { try await search.start() } onCancel: { Task { @MainActor in search.cancel() } }
        try Task.checkCancellation()
        return response.mapItems.map(candidate)
    }
    func leg(from: AppleRouteCoordinate, to: AppleRouteCoordinate) async throws -> RouteMapLeg {
        let request = MKDirections.Request()
        request.source = item(from); request.destination = item(to)
        request.transportType = .automobile; request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        let response = try await withTaskCancellationHandler { try await directions.calculate() } onCancel: { Task { @MainActor in directions.cancel() } }
        try Task.checkCancellation()
        guard let route = response.routes.first else { throw RouteMapError.directionsUnavailable }
        let polyline = route.polyline
        var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        return RouteMapLeg(distanceMeters: route.distance, coordinates: coordinates.map { AppleRouteCoordinate(latitude: $0.latitude, longitude: $0.longitude) })
    }
    private func candidate(_ item: MKMapItem) -> RouteMapCandidate {
        let coordinate: CLLocationCoordinate2D
        let address: String
        if #available(macOS 26.0, *) { coordinate = item.location.coordinate; address = item.address?.fullAddress ?? "" }
        else { coordinate = item.placemark.coordinate; address = item.placemark.title ?? "" }
        return RouteMapCandidate(coordinate: AppleRouteCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude), address: address)
    }
    private func item(_ coordinate: AppleRouteCoordinate) -> MKMapItem {
        if #available(macOS 26.0, *) { return MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil) }
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate.location))
    }
}

extension AppleRouteCoordinate {
    var location: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
