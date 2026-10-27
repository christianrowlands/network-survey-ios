import Foundation

/// How to reach the NS Tower Service.
public struct TowerServiceConfig: Sendable, Equatable {
    /// The API Gateway in front of the tower service, shared with the Android app.
    public static let gatewayURL = URL(string: "https://network-survey-gateway-2z7o328z.uc.gateway.dev/")!

    public var baseURL: URL
    /// Empty in builds without a key (forks and contributors): no requests are made.
    public var apiKey: String
    /// Sent so the gateway accepts a key restricted to this app.
    public var bundleID: String
    public var appVersion: String

    public init(baseURL: URL = TowerServiceConfig.gatewayURL, apiKey: String, bundleID: String, appVersion: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey.trimmingCharacters(in: .whitespaces)
        self.bundleID = bundleID
        self.appVersion = appVersion
    }

    public var hasKey: Bool { !apiKey.isEmpty }

    /// Added to every request. The gateway logs the query string but no
    /// headers, so this is how the service's usage analytics tell iOS from
    /// Android (whose requests have no `platform`) and see app versions.
    var clientQuery: [URLQueryItem] {
        [URLQueryItem(name: "platform", value: "ios"), URLQueryItem(name: "app_version", value: appVersion)]
    }
}

public enum TowerServiceError: Error, Equatable, Sendable {
    case missingKey
    /// The box is empty, inverted or crosses the antimeridian; nothing was sent.
    case unqueryableArea
    case network
    case server(status: Int)
    case badResponse
}

public protocol TowerTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTowerTransport: TowerTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: SameHostRedirects())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Refuses redirects to another host, which would carry the API key with them.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.host?.lowercased() == task.originalRequest?.url?.host?.lowercased() ? request : nil
    }
}

/// An operator's name from the service's MCC-MNC list.
public struct PlmnInfo: Sendable, Equatable {
    public var name: String
    public var country: String?

    public init(name: String, country: String? = nil) {
        self.name = name
        self.country = country
    }
}

/// The NS Tower Service API used by the tower map.
public struct TowerClient: Sendable {
    public let config: TowerServiceConfig
    private let transport: any TowerTransport

    public init(config: TowerServiceConfig, transport: any TowerTransport = URLSessionTowerTransport()) {
        self.config = config
        self.transport = transport
    }

    /// Towers in `bounds` (`/v2/cells/area`), up to the server's cap of 5,000.
    public func towers(in bounds: GeoBounds, filters: TowerFilters, now: Date = .now) async throws(TowerServiceError) -> TowerBatch {
        guard let bbox = bounds.bboxParameter else { throw .unqueryableArea }
        let data = try await get("v2/cells/area", filters.queryItems(bbox: bbox, now: now))
        return try decode(TowerBatch.self, data) ?? .empty
    }

    /// Towers with this identity in any technology (`/v2/cells/search`).
    public func search(mcc: String, mnc: String, area: Int, cid: Int64) async throws(TowerServiceError) -> [Tower] {
        let data = try await get("v2/cells/search", [
            URLQueryItem(name: "mcc", value: mcc), URLQueryItem(name: "mnc", value: mnc),
            URLQueryItem(name: "area", value: String(area)), URLQueryItem(name: "cid", value: String(cid)),
        ])
        return try decode(TowerBatch.self, data)?.towers ?? []
    }

    /// Operator names (`/v2/plmn/batch`). Unknown operators are left out.
    public func operators(_ plmns: [Plmn]) async throws(TowerServiceError) -> [Plmn: PlmnInfo] {
        guard !plmns.isEmpty else { return [:] }
        let body = PlmnBatchRequest(plmns: plmns.prefix(1000).map { .init(mcc: $0.mcc, mnc: $0.mnc) })
        let data = try await send(request("v2/plmn/batch", [], method: "POST", body: try? JSONEncoder().encode(body)))
        guard let response = try decode(PlmnBatchResponse.self, data) else { return [:] }
        var names: [Plmn: PlmnInfo] = [:]
        for (asked, result) in zip(plmns, response.results) where !result.isUnknown {
            guard let record = result.records?.first,
                  let name = (record.brand ?? record.operator)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            names[asked] = PlmnInfo(name: name, country: record.country)
        }
        return names
    }

    // MARK: - Requests

    private func get(_ path: String, _ query: [URLQueryItem]) async throws(TowerServiceError) -> Data? {
        try await send(request(path, query, method: "GET", body: nil))
    }

    func request(_ path: String, _ query: [URLQueryItem], method: String, body: Data?) -> URLRequest {
        var components = URLComponents(url: config.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query + config.clientQuery
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(config.bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// The response body, or nil for 204 (nothing matched).
    private func send(_ request: URLRequest) async throws(TowerServiceError) -> Data? {
        guard config.hasKey else { throw .missingKey }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw .network
        }
        switch response.statusCode {
        case 204: return nil
        case 200..<300: return data
        default: throw .server(status: response.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data?) throws(TowerServiceError) -> T? {
        guard let data, !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .badResponse
        }
    }
}

private struct PlmnBatchRequest: Encodable {
    struct Item: Encodable {
        var mcc: String
        var mnc: String
    }

    var plmns: [Item]
}

private struct PlmnBatchResponse: Decodable {
    struct Result: Decodable {
        var records: [Record]?
        var isUnknown: Bool

        enum CodingKeys: String, CodingKey {
            case records
            case isUnknown = "is_unknown"
        }
    }

    struct Record: Decodable {
        var `operator`: String?
        var brand: String?
        var country: String?
    }

    var results: [Result]
}
