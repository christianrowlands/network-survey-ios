import Foundation
import Testing
@testable import NSMessaging

/// Fixture helpers shared by the test files.
enum Fixtures {
    struct Missing: Error { let path: String }

    static func url(_ path: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil) else { throw Missing(path: path) }
        return url
    }

    static func text(_ path: String) throws -> String {
        try String(contentsOf: try url(path), encoding: .utf8)
    }

    /// Writes what a test produced next to the build products, so a new golden
    /// can be checked with the Java tooling before it is committed.
    static func saveActual(_ text: String, as name: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns-messaging-actual")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}

@Test("Targets NS Messaging API 2.6.0")
func apiVersion() {
    #expect(NSMessaging.apiVersion == "2.6.0")
}

/// Each fixture line holds a value and what the Java runtime printed for it:
/// `%.6f`, DecimalFormat("#.##") CEILING of the double and of the float,
/// Float.toString and Double.toString.
@Test("Number formatting matches the Java runtime")
func javaNumberFormatting() throws {
    let lines = try Fixtures.text("java-number-format.txt").split(separator: "\n")
    #expect(lines.count > 200)
    for line in lines {
        let columns = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let value = try #require(Double(columns[0]))
        let float = Float(value)
        #expect(JavaNumberFormat.fixed(value, decimals: 6) == columns[1], "\(columns[0]) %.6f")
        #expect(JavaNumberFormat.ceilingTwoDecimals(value) == columns[2], "\(columns[0]) #.##")
        #expect(JavaNumberFormat.ceilingTwoDecimals(Double(float)) == columns[3], "\(columns[0]) #.## float")
        #expect(JavaNumberFormat.string(float) == columns[4], "\(columns[0]) Float.toString")
        #expect(JavaNumberFormat.string(value) == columns[5], "\(columns[0]) Double.toString")
    }
}

@Test("deviceTime is ISO_OFFSET_DATE_TIME at millisecond precision")
func deviceTimeFormat() throws {
    let date = Date(timeIntervalSince1970: 1_792_000_987.120_9)
    #expect(DeviceTime.string(date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-14T18:03:07.12Z")
    let minus5 = try #require(TimeZone(secondsFromGMT: -5 * 3600))
    #expect(DeviceTime.string(date, timeZone: minus5) == "2026-10-14T13:03:07.12-05:00")
    let whole = Date(timeIntervalSince1970: 1_792_000_987)
    let plus530 = try #require(TimeZone(secondsFromGMT: 5 * 3600 + 1800))
    #expect(DeviceTime.string(whole, timeZone: plus530) == "2026-10-14T23:33:07+05:30")
    let early = Date(timeIntervalSince1970: -1.5)
    #expect(DeviceTime.string(early, timeZone: TimeZone(identifier: "UTC")!) == "1969-12-31T23:59:58.5Z")
    let leap = Date(timeIntervalSince1970: 951_782_400.001) // 2000-02-29
    #expect(DeviceTime.string(leap, timeZone: TimeZone(identifier: "UTC")!) == "2000-02-29T00:00:00.001Z")
}

@Test("Strings are escaped like Gson")
func gsonEscaping() {
    var output = ""
    let input = "a<b>&='\"\\\n\t\r\u{08}\u{0C}\u{01}\u{1F}\u{E9}\u{2028}\u{2029}/\u{1F4E1}"
    NSJSONWriter.escape(input, into: &output)
    let u = "\\u"
    let expected = "a\(u)003cb\(u)003e\(u)0026\(u)003d\(u)0027\\\"\\\\\\n\\t\\r\\b\\f\(u)0001\(u)001f\u{E9}\(u)2028\(u)2029/\u{1F4E1}"
    #expect(output == expected)
}
