import Foundation
import Testing
@testable import Towers

/// Fails every request as if there were no connection.
private struct OfflineTransport: TowerTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

@Suite struct PlmnSearchQueryTests {
    @Test func codesAreReadAsMCCAndMNC() {
        #expect(PlmnSearchQuery("310") == .code(mcc: "310", mnc: nil))
        #expect(PlmnSearchQuery(" 31 ") == .code(mcc: "31", mnc: nil))
        #expect(PlmnSearchQuery("310-260") == .code(mcc: "310", mnc: "260"))
        #expect(PlmnSearchQuery("310260") == .code(mcc: "310", mnc: "260"))
        #expect(PlmnSearchQuery("262 01") == .code(mcc: "262", mnc: "01"))
        #expect(PlmnSearchQuery("310-") == .code(mcc: "310", mnc: nil))
        #expect(PlmnSearchQuery("3102601") == .text("3102601"))
    }

    @Test func namesAreText() {
        #expect(PlmnSearchQuery("Germany") == .text("Germany"))
        #expect(PlmnSearchQuery("  t-mobile ") == .text("t-mobile"))
        #expect(PlmnSearchQuery("UK") == .text("UK"))
        #expect(PlmnSearchQuery(String(repeating: "a", count: 100)) == .text(String(repeating: "a", count: 64)))
    }

    @Test func tooShortIsNoSearch() {
        #expect(PlmnSearchQuery("") == nil)
        #expect(PlmnSearchQuery("  3 ") == nil)
        #expect(PlmnSearchQuery("a") == nil)
    }
}

@Suite struct PlmnSearchTests {
    private func client(_ transport: any TowerTransport, key: String = "test-key") -> TowerClient {
        TowerClient(config: TowerServiceConfig(apiKey: key, bundleID: "app.example.survey", appVersion: "0.2.0"), transport: transport)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }) { $1 }
    }

    @Test func aTextSearchSendsQAndSortsByCode() async throws {
        let transport = StubTransport(body: #"""
            {"dataset_version":"x","count":3,"truncated":true,"results":[
            {"mcc":"505","mnc":"03","plmn":"50503","region":"Oceania","country":"Australia","iso":"AU","operator":"Example Telecom","brand":"ExampleNet","tadig":"AUSEX","bands":"LTE 850 / 5G 3500","status":"Operational"},
            {"mcc":"276","mnc":"02","plmn":"27602","country":"Albania","iso":"AL","operator":"ExampleNet Albania","brand":"ExampleNet","status":"Operational"},
            {"mcc":"276","mnc":"02","plmn":"27602","country":"Albania","iso":"AL","operator":"ExampleNet Albania","brand":"ExampleNet","status":"Operational"},
            {"mcc":"505","mnc":"06","plmn":"50506","country":"Australia","iso":"AU","operator":"Sample Mobile","brand":"3","status":"Not operational"}]}
            """#)
        let result = try await client(transport).searchOperators(.text("example"))

        #expect(result.truncated)
        #expect(result.records.map(\.plmn.description) == ["276-02", "505-03", "505-06"])
        let first = try #require(result.records.first)
        #expect(first.name == "ExampleNet" && first.operatorName == "ExampleNet Albania")
        #expect(first.flag == "🇦🇱" && first.isOperational)
        #expect(result.records[1].tadig == "AUSEX" && result.records[1].bands == "LTE 850 / 5G 3500")
        #expect(!result.records[2].isOperational)

        let request = try #require(transport.sent.first)
        #expect(request.url!.path == "/v2/plmn/search")
        #expect(request.httpMethod == "GET")
        let items = query(request)
        #expect(items["q"] == "example" && items["limit"] == "50")
        #expect(items["mcc"] == nil)
        #expect(items["platform"] == "ios")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
    }

    @Test func aCodeSearchSendsMCCAndMNC() async throws {
        let transport = StubTransport(body: #"{"count":0,"truncated":false,"results":[]}"#)
        let result = try await client(transport).searchOperators(.code(mcc: "310", mnc: "26"))
        #expect(result == PlmnSearchResult(records: [], truncated: false))
        let items = query(try #require(transport.sent.first))
        #expect(items["mcc"] == "310" && items["mnc"] == "26" && items["q"] == nil)

        _ = try await client(transport).searchOperators(.code(mcc: "31", mnc: nil))
        let mccOnly = query(try #require(transport.sent.last))
        #expect(mccOnly["mcc"] == "31" && mccOnly["mnc"] == nil)
    }

    @Test func failuresAreReported() async {
        let transport = StubTransport()
        await #expect(throws: TowerServiceError.missingKey) {
            try await client(transport, key: "").searchOperators(.text("example"))
        }
        #expect(transport.sent.isEmpty)
        await #expect(throws: TowerServiceError.network) {
            try await client(OfflineTransport()).searchOperators(.text("example"))
        }
        await #expect(throws: TowerServiceError.server(status: 503)) {
            try await client(StubTransport(status: 503)).searchOperators(.text("example"))
        }
        await #expect(throws: TowerServiceError.badResponse) {
            try await client(StubTransport(body: "<html>")).searchOperators(.text("example"))
        }
    }

    @Test func namesAndFlags() {
        let record = PlmnRecord(mcc: "001", mnc: "01", iso: "BQ/CW/SX", operator: "Example Mobile", brand: "example mobile")
        #expect(record.name == "example mobile" && record.operatorName == nil)
        #expect(record.flag == nil)
        #expect(PlmnRecord(mcc: "001", mnc: "01", iso: "xx").flag == nil)
        #expect(PlmnRecord(mcc: "001", mnc: "01", operator: " ", brand: "").name == nil)
        #expect(PlmnRecord(mcc: "001", mnc: "01", operator: "Example Mobile").name == "Example Mobile")
    }
}
