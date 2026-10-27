import Foundation
import Testing
@testable import Towers

/// Answers every request with one canned response and keeps what was sent.
private final class StubTransport: TowerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    let status: Int
    let body: String

    init(status: Int = 200, body: String = "") {
        self.status = status
        self.body = body
    }

    var sent: [URLRequest] { lock.withLock { log } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { log.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite struct TowerClientTests {
    let box = GeoBounds(south: 52.2, west: 20.9, north: 52.3, east: 21.1)

    private func client(_ transport: StubTransport, key: String = "test-key") -> TowerClient {
        TowerClient(
            config: TowerServiceConfig(apiKey: key, bundleID: "app.example.survey", appVersion: "0.2.0"),
            transport: transport
        )
    }

    @Test func anAreaRequestCarriesTheFiltersAndHeaders() async throws {
        let transport = StubTransport(body: #"{"count":1,"cells":[{"lat":52.25,"lon":21.0,"mcc":"260","mnc":"01","area":1234,"cid":26881281,"unit":101,"average_signal":0,"range":1200,"samples":14,"changeable":1,"created_at":1600000000,"updated_at":1700000000,"radio":"LTE","source":"OpenCelliD"}]}"#)
        let filters = TowerFilters(technologies: [.nr, .lte], plmn: Plmn(mcc: "260", mnc: "01"), maxAge: .oneYear)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let batch = try await client(transport).towers(in: box, filters: filters, now: now)

        #expect(batch.towers.count == 1 && !batch.truncated)
        let tower = try #require(batch.towers.first)
        #expect(tower.mnc == "01")
        #expect(tower.technology == .lte)
        #expect(tower.eNodeB?.id == 105_005 && tower.eNodeB?.sector == 1)

        let request = try #require(transport.sent.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(request.url!.path == "/v2/cells/area")
        #expect(query["bbox"] == "52.2,20.9,52.3,21.1")
        #expect(query["radio"] == "LTE,NR")
        #expect(query["source"] == "OpenCelliD")
        #expect(query["mcc"] == "260" && query["mnc"] == "01")
        #expect(query["updated_after"] == String(1_800_000_000 - 12 * 30 * 86_400))
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "X-Ios-Bundle-Identifier") == "app.example.survey")
        #expect(query["platform"] == "ios" && query["app_version"] == "0.2.0")
    }

    @Test func noContentMeansNoTowers() async throws {
        let batch = try await client(StubTransport(status: 204)).towers(in: box, filters: TowerFilters())
        #expect(batch == .empty)
    }

    @Test func truncationIsPassedThrough() async throws {
        let batch = try await client(StubTransport(body: #"{"count":0,"cells":[],"truncated":true}"#)).towers(in: box, filters: TowerFilters())
        #expect(batch.truncated)
    }

    @Test func withoutAKeyNothingIsSent() async {
        let transport = StubTransport()
        await #expect(throws: TowerServiceError.missingKey) {
            try await client(transport, key: " ").towers(in: box, filters: TowerFilters())
        }
        #expect(transport.sent.isEmpty)
    }

    @Test func anUnqueryableAreaIsNotSent() async {
        let transport = StubTransport()
        await #expect(throws: TowerServiceError.unqueryableArea) {
            try await client(transport).towers(in: GeoBounds(south: 0, west: 179, north: 1, east: -179), filters: TowerFilters())
        }
        #expect(transport.sent.isEmpty)
    }

    @Test func serverErrorsAreReported() async {
        await #expect(throws: TowerServiceError.server(status: 429)) {
            try await client(StubTransport(status: 429)).towers(in: box, filters: TowerFilters())
        }
        await #expect(throws: TowerServiceError.badResponse) {
            try await client(StubTransport(body: "not json")).towers(in: box, filters: TowerFilters())
        }
    }

    @Test func operatorNamesPreferTheBrand() async throws {
        let transport = StubTransport(body: #"{"dataset_version":"x","count":2,"results":[{"mcc":"260","mnc":"01","records":[{"mcc":"260","mnc":"01","plmn":"26001","operator":"Example Mobile Sp. z o.o.","brand":"ExampleNet","country":"Poland"}],"is_unknown":false},{"mcc":"999","mnc":"99","is_unknown":true}]}"#)
        let names = try await client(transport).operators([Plmn(mcc: "260", mnc: "01"), Plmn(mcc: "999", mnc: "99")])
        #expect(names == [Plmn(mcc: "260", mnc: "01"): PlmnInfo(name: "ExampleNet", country: "Poland")])
        let sent = try #require(transport.sent.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.query()?.contains("platform=ios") == true)
    }
}

@Suite struct PlmnPaletteTests {
    /// Values from the Android app's `(mcc * 31 + mnc) % 16`.
    @Test func matchesTheAndroidHash() {
        #expect(PlmnPalette.index(for: Plmn(mcc: "310", mnc: "260")) == 14)
        #expect(PlmnPalette.index(for: Plmn(mcc: "260", mnc: "01")) == 13)
        #expect(PlmnPalette.index(for: Plmn(mcc: "001", mnc: "01")) == 0)
        #expect(PlmnPalette.index(for: Plmn(mcc: "x", mnc: "y")) == 0)
    }
}

@Suite struct TowerFilterValueTests {
    @Test func storedMonthsMapToAnAge() {
        #expect(TowerAge(months: 12) == .oneYear)
        #expect(TowerAge(months: 0) == .any)
        #expect(TowerAge(months: 7) == .any)
    }

    @Test func operatorCodesParse() {
        #expect(Plmn(string: "310-410") == Plmn(mcc: "310", mnc: "410"))
        #expect(Plmn(string: "260-01")?.description == "260-01")
        #expect(Plmn(string: "") == nil)
        #expect(Plmn(string: "31-410") == nil)
        #expect(Plmn(string: "310-4a0") == nil)
    }
}
