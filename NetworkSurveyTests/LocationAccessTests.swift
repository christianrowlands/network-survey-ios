import Foundation
import SurveyCore
import Synchronization
import Testing
@testable import NetworkSurvey

@MainActor
@Suite("Location access")
struct LocationAccessTests {
    /// The system-wide Location Services switch, as the fake reads it.
    final class ServicesSwitch: Sendable {
        let isOn = Mutex(true)
    }

    private func makeModel(_ authorization: LocationAuthorization, servicesOn: Bool = true)
        -> (AccessModel, SimulatedLocationProvider, ServicesSwitch) {
        let provider = SimulatedLocationProvider(timeSource: .manual)
        provider.setAuthorization(authorization)
        let services = ServicesSwitch()
        services.isOn.withLock { $0 = servicesOn }
        let model = AccessModel(locationProvider: provider) { services.isOn.withLock { $0 } }
        return (model, provider, services)
    }

    @Test("Authorization and the Location Services switch map to one state")
    func mapping() {
        #expect(LocationAccess(authorization: .notDetermined, servicesEnabled: true) == .notDetermined)
        #expect(LocationAccess(authorization: .denied, servicesEnabled: true) == .denied)
        #expect(LocationAccess(authorization: .restricted, servicesEnabled: true) == .restricted)
        #expect(LocationAccess(authorization: .whenInUse(precise: true), servicesEnabled: true) == .ready)
        #expect(LocationAccess(authorization: .whenInUse(precise: false), servicesEnabled: true) == .approximate)
        // Core Location says denied for every app while Location Services are off,
        // even one that never asked: that is not the app's own switch.
        #expect(LocationAccess(authorization: .denied, servicesEnabled: false) == .servicesOff)
        #expect(LocationAccess(authorization: .notDetermined, servicesEnabled: false) == .servicesOff)
        #expect(LocationAccess.servicesOff.blocksRecords && LocationAccess.restricted.blocksRecords)
        #expect(LocationAccess.denied.blocksRecords && !LocationAccess.notDetermined.blocksRecords)
        #expect(LocationAccess.approximate.isAllowed && !LocationAccess.approximate.blocksRecords)
    }

    @Test("Each state gets a notice that leads somewhere that works")
    func notices() throws {
        #expect(LocationNotice(.ready) == nil)
        #expect(LocationNotice(.notDetermined)?.action == .allow)
        let off = try #require(LocationNotice(.servicesOff))
        #expect(off.title == "Location Services are off")
        #expect(off.detail.contains("Settings > Privacy & Security > Location Services"))
        // The app's Settings page has no Location row to switch here; the system
        // alert links to the Location Services page instead.
        #expect(off.action == .turnOnServices)
        let restricted = try #require(LocationNotice(.restricted))
        #expect(restricted.title == "Location is restricted on this iPhone")
        #expect(restricted.action == nil)
        let denied = try #require(LocationNotice(.denied))
        #expect(denied.title == "Location access is off")
        #expect(denied.action == .openSettings)
        #expect(LocationNotice(.approximate)?.action == .usePrecise)
        let all: [LocationAccess] = [.notDetermined, .servicesOff, .restricted, .denied, .approximate]
        #expect(Set(all.compactMap { LocationNotice($0)?.id }).count == all.count)
    }

    @Test("Turning on Location Services brings back the Allow prompt for an app that never asked")
    func servicesOffThenOn() async {
        let (model, provider, services) = makeModel(.denied, servicesOn: false)
        await model.refresh()
        #expect(model.location == .servicesOff)
        // iOS gives the app its previous state back when the switch comes on.
        provider.setAuthorization(.notDetermined)
        services.isOn.withLock { $0 = true }
        await model.refresh()
        #expect(model.location == .notDetermined)
        await model.perform(.allow)
        #expect(model.location == .ready)
    }

    @Test("Use precise location asks for full accuracy")
    func precise() async {
        let (model, _, _) = makeModel(.whenInUse(precise: false))
        await model.refresh()
        #expect(model.location == .approximate)
        await model.perform(.usePrecise)
        #expect(model.location == .ready)
    }

    @Test("Denied by the user stays denied until Settings changes it")
    func denied() async {
        let (model, provider, _) = makeModel(.denied)
        await model.refresh()
        #expect(model.location == .denied)
        await model.perform(.allow)
        #expect(model.location == .denied)
        provider.setAuthorization(.whenInUse(precise: true))
        await model.refresh()
        #expect(model.location == .ready)
    }
}
