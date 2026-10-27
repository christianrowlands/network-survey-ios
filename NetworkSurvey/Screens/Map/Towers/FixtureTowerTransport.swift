import Foundation
import Towers

/// Made-up towers for UI tests and screenshots, so they never reach the tower
/// service. Towers sit on a fixed grid, so the same place always has the same
/// towers; test network operators (MCC 001) with made-up names.
nonisolated struct FixtureTowerTransport: TowerTransport {
    static let spacing = 0.004
    static let limit = 400
    static let operators = [
        (Plmn(mcc: "001", mnc: "01"), "ExampleNet"),
        (Plmn(mcc: "001", mnc: "02"), "Sample Mobile"),
        (Plmn(mcc: "001", mnc: "03"), "Test Wireless"),
    ]

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        ) { $1 }
        let body: Data
        switch url.lastPathComponent {
        case "area": body = try area(query)
        case "batch": body = try names()
        // Any search finds the grid tower nearest Denver, so tests can jump to a known spot.
        case "search": body = try JSONEncoder().encode(Batch(cells: [Self.tower(row: 9935, column: -26248)], truncated: false))
        default: body = try JSONEncoder().encode(Batch(cells: [], truncated: false))
        }
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func area(_ query: [String: String]) throws -> Data {
        let box = (query["bbox"] ?? "").split(separator: ",").compactMap { Double($0) }
        guard box.count == 4 else { return try JSONEncoder().encode(Batch(cells: [], truncated: false)) }
        let radios = Set((query["radio"] ?? "").split(separator: ",").map(String.init))
        var cells: [Tower] = []
        var truncated = false
        let rows = Int((box[0] / Self.spacing).rounded(.up))...Int((box[2] / Self.spacing).rounded(.down))
        let columns = Int((box[1] / Self.spacing).rounded(.up))...Int((box[3] / Self.spacing).rounded(.down))
        grid: for row in rows {
            for column in columns {
                for tower in Self.site(row: row, column: column) {
                    guard radios.contains(tower.radio), query["mcc"].map({ $0 == tower.mcc }) ?? true,
                          query["mnc"].map({ $0 == tower.mnc }) ?? true else { continue }
                    guard cells.count < Self.limit else {
                        truncated = true
                        break grid
                    }
                    cells.append(tower)
                }
            }
        }
        return try JSONEncoder().encode(Batch(cells: cells, truncated: truncated))
    }

    /// One grid point: a tower, and at every fifth site a second technology
    /// on the same mast.
    static func site(row: Int, column: Int) -> [Tower] {
        let tower = tower(row: row, column: column)
        guard abs(row &* 31 &+ column) % 5 == 0 else { return [tower] }
        var second = tower
        second.radio = tower.radio == TowerRadio.nr.rawValue ? TowerRadio.lte.rawValue : TowerRadio.nr.rawValue
        second.cid += 1
        return [tower, second]
    }

    static func tower(row: Int, column: Int) -> Tower {
        let seed = abs(row &* 73_856_093 ^ column &* 19_349_663)
        let (plmn, _) = operators[seed % operators.count]
        let radio: TowerRadio = seed % 3 == 0 ? .nr : .lte
        // Off the grid by up to a third of a step, so sites look scattered.
        let jitterLat = Double(seed % 61 - 30) / 90 * spacing, jitterLon = Double(seed / 61 % 61 - 30) / 90 * spacing
        return Tower(
            lat: Double(row) * spacing + jitterLat, lon: Double(column) * spacing + jitterLon, mcc: plmn.mcc, mnc: plmn.mnc,
            area: 1000 + seed % 50, cid: Int64(seed % 1_000_000) * 256 + Int64(seed % 3), unit: seed % 504,
            range: 400 + seed % 1600, samples: 5 + seed % 200, changeable: 1,
            createdAt: 1_600_000_000, updatedAt: 1_780_000_000 - Int64(seed % 10_000_000), radio: radio.rawValue
        )
    }

    private func names() throws -> Data {
        let results = Self.operators.map { plmn, name in
            ["mcc": plmn.mcc, "mnc": plmn.mnc, "is_unknown": false,
             "records": [["mcc": plmn.mcc, "mnc": plmn.mnc, "plmn": plmn.mcc + plmn.mnc, "brand": name]]] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: ["results": results])
    }

    private struct Batch: Encodable {
        var cells: [Tower]
        var truncated: Bool
    }
}
