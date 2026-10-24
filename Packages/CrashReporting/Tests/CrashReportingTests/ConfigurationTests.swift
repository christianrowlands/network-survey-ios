import Testing
@testable import CrashReporting

@Suite("Crash reporting configuration")
struct ConfigurationTests {
    @Test("A Sentry DSN is accepted")
    func validDSN() throws {
        let configuration = try #require(
            CrashReporter.Configuration(dsn: " https://abc123@o1.ingest.sentry.io/42\n", release: "r", environment: "production"))
        #expect(configuration.dsn == "https://abc123@o1.ingest.sentry.io/42")
    }

    @Test("No DSN, or one the build left unexpanded, means no crash reporting",
          arguments: [nil, "", "  ", "$(SENTRY_DSN)", "https://o1.ingest.sentry.io/42", "ftp://abc@example.com/1", "not a url"])
    func missingDSN(dsn: String?) {
        #expect(CrashReporter.Configuration(dsn: dsn, release: "r", environment: "production") == nil)
    }
}
