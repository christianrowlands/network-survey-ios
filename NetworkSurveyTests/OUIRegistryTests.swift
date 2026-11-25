import Testing
@testable import NetworkSurvey

@Suite("OUI registry")
struct OUIRegistryTests {
    private let table = OUIRegistry.Table.parse("""
    70B3D5\tIEEE Registration Authority
    70B3D51FA\tExample Sensors Ltd
    ACDE48\tPrivate
    C85CE2\tIEEE Registration Authority
    C85CE27\tSynergy Systems
    F01898\tApple, Inc.

    garbage line
    12345\tWrong width
    """)

    private func match(_ text: String) -> OUIMatch? {
        OUIRegistry.hexDigits(text).flatMap { $0.count >= 6 ? OUIRegistry.lookup(digits: $0, in: table) : nil }
    }

    @Test func parsesEachRegistryByPrefixWidth() {
        #expect(table.count == 6)
        #expect(table.names[.maL]?.count == 4)
        #expect(table.names[.maM]?.count == 1)
        #expect(table.names[.maS]?.count == 1)
    }

    @Test func findsTheVendorInAnyAddressFormat() {
        for text in ["F0:18:98:12:34:56", "f0-18-98-12-34-56", "f018.9812.3456", "F01898123456", "f01898"] {
            #expect(match(text)?.vendor == "Apple, Inc.", "\(text)")
        }
        #expect(match("F0:18:98:12:34:56") == OUIMatch(kind: .vendor("Apple, Inc."), registry: .maL, prefix: "F0:18:98"))
    }

    @Test func theMostSpecificBlockWins() {
        #expect(match("70:B3:D5:1F:A0:01") == OUIMatch(kind: .vendor("Example Sensors Ltd"), registry: .maS, prefix: "70:B3:D5:1F:A"))
        #expect(match("C8:5C:E2:70:00:01") == OUIMatch(kind: .vendor("Synergy Systems"), registry: .maM, prefix: "C8:5C:E2:7"))
        // Too few digits for the smaller block, or a block nobody registered.
        #expect(match("70B3D5")?.kind == .sharedBlock)
        #expect(match("70:B3:D5:00:00:01")?.kind == .sharedBlock)
    }

    @Test func privateRegistrationsHaveNoVendorName() {
        let result = match("AC:DE:48:00:11:22")
        #expect(result?.kind == .privateVendor)
        #expect(result?.vendor == nil)
    }

    @Test func randomizedAndMulticastAddressesAreNotLookedUp() {
        // F2 has the locally administered bit set; F1 the group bit.
        #expect(match("F2:18:98:12:34:56")?.kind == .locallyAdministered)
        #expect(match("F1:18:98:12:34:56")?.kind == .multicast)
        #expect(match("FF:FF:FF:FF:FF:FF")?.kind == .multicast)
    }

    @Test func unknownPrefixesAndBadInput() {
        #expect(match("00:11:22:33:44:55")?.kind == .notFound)
        #expect(OUIRegistry.hexDigits("F0:18:9G") == nil)
        #expect(OUIRegistry.hexDigits("F0:18:98:12:34:56:78") == nil)
        #expect(OUIRegistry.hexDigits("f0 18") == "F018")
    }

    @Test func shortNamesDropLegalSuffixes() {
        let cases = [
            "HUAWEI TECHNOLOGIES CO.,LTD": "HUAWEI TECHNOLOGIES",
            "Apple, Inc.": "Apple",
            "Cisco Systems, Inc": "Cisco Systems",
            "Samsung Electronics Co.,Ltd": "Samsung Electronics",
            "Intel Corporate": "Intel",
            "zte corporation": "zte",
            "TP-LINK TECHNOLOGIES CO.,LTD.": "TP-LINK TECHNOLOGIES",
            "Xiaomi Communications Co Ltd": "Xiaomi Communications",
            "Sagemcom Broadband SAS": "Sagemcom Broadband",
            "ICANN, IANA Department": "ICANN, IANA Department",
            "Juniper Networks": "Juniper Networks",
            "Telco": "Telco",
            "Inc": "Inc",
        ]
        for (name, short) in cases {
            #expect(OUIRegistry.shortName(name) == short, "\(name)")
        }
    }

    @Test func theBundledRegistryLoads() {
        #expect(OUIRegistry.table.count > 50_000)
        #expect(OUIRegistry.vendor(for: "00:00:00:00:00:01") == "XEROX CORPORATION")
    }

    /// RFC 7042's documentation range has no maker; the rest of IANA's block
    /// (VRRP's virtual routers, for one) does, and the lookup tool still
    /// shows the block for a documentation address.
    @Test func theDocumentationRangeHasNoManufacturer() {
        #expect(OUIRegistry.vendor(for: "00:00:5E:00:53:13") == nil)
        #expect(OUIRegistry.vendor(for: "00:00:5E:00:01:01") == "ICANN, IANA Department")
        #expect(OUIRegistry.lookup("00:00:5E:00:53:13")?.vendor == "ICANN, IANA Department")
    }
}
