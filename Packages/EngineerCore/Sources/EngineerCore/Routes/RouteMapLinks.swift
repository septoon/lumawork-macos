import Foundation

public enum RouteMapLinks {
    public static func webURL(baseURL: String?, addresses: [String], coordinateOverrides: [AppleRouteCoordinate?] = []) -> URL? {
        guard let baseURL, let url = try? AppConfig.validatedURL(baseURL),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let points = addresses.indices.compactMap { index -> String? in
            let address = addresses[index].normalizedAddressCommaSpacing()
            guard !address.isEmpty else { return nil }
            if coordinateOverrides.indices.contains(index), let coordinate = coordinateOverrides[index], coordinate.isValid {
                return "\(coordinate.latitude),\(coordinate.longitude)"
            }
            return address.qualifiedRouteAddress()
        }
        guard points.count >= 2 else { return nil }
        components.queryItems = [
            URLQueryItem(name: "rtext", value: points.joined(separator: "~")),
            URLQueryItem(name: "rtt", value: "auto"),
            URLQueryItem(name: "routes[avoid]", value: "unpaved,poor_condition")
        ]
        return components.url
    }
}
