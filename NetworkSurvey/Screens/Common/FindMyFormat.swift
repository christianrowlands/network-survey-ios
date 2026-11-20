import NearbyKit
import NSMessaging
import SurveyCore
import SwiftUI

/// Find My wording for Bluetooth devices, shared by the NS Scout list, its
/// detail screen and Nearby Bluetooth.
nonisolated enum FindMyFormat {
    /// The detail screen's "Find My type".
    static func label(_ device: FindMyDevice) -> String {
        switch device {
        case .appleDevice: "Apple device"
        case .airTag: "AirTag"
        case .accessory: "Tracker or accessory"
        case .airPods: "AirPods"
        }
    }

    /// The tag for a tracker: "AirTag", or "Find My" when the kind can't be
    /// told without connecting. Nil when it is not a tracker.
    static func tag(_ device: FindMyDevice?) -> String? {
        guard let device, device.isTracker else { return nil }
        return device == .airTag ? "AirTag" : "Find My"
    }
}

/// The tag a Find My tracker gets in lists and detail headers. Shows nothing
/// for other devices.
struct FindMyTag: View {
    let device: FindMyDevice?

    var body: some View {
        if let text = FindMyFormat.tag(device) {
            TagPill(text: text, color: Theme.Colors.tagTracker)
                .accessibilityLabel(device == .airTag ? "AirTag tracker" : "Find My tracker")
        }
    }
}

extension BLEDeviceRow {
    /// What sent the last advertisement, when it was Find My.
    var findMy: FindMyDevice? { FindMy.device(advertisingData: advData) }
}

extension NearbyDevice {
    /// What sent the last manufacturer data, when it was Find My. On screen
    /// only, like everything Nearby Bluetooth hears.
    var findMy: FindMyDevice? { manufacturerData.flatMap { FindMy.device(manufacturerData: $0) } }
}
