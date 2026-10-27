import Foundation

/// Every web page the app links to, in one place.
enum Links {
    static let website = URL(string: "https://networksurvey.app")!
    /// The same privacy policy page the Network Survey Android app links to.
    static let privacyPolicy = URL(string: "https://networksurvey.app/privacy-policy")!

    // MARK: NS Scout

    /// What an NS Scout is, what to buy and where, and how to set it up.
    static let scout = URL(string: "https://networksurvey.app/scout")!
    /// The web installer for the Scout firmware (Chrome or Edge on a computer).
    static let scoutInstaller = URL(string: "https://install.networksurvey.app/")!

    // MARK: NS Analytics

    /// The host shown in instructions, without the scheme.
    static let nsAnalyticsHost = "analytics.networksurvey.app"

    // MARK: Tower data

    /// OpenCelliD, the main tower source (CC BY-SA 4.0, credited on the map).
    static let openCelliD = URL(string: "https://opencellid.org")!
    /// BTSearch, the tower source for Poland.
    static let btSearch = URL(string: "https://btsearch.pl")!
}
