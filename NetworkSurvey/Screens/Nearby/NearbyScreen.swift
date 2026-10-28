import BoardKit
import NearbyKit
import SwiftUI

/// Nearby Bluetooth: a live list of what this iPhone's own radio hears. A
/// separate space from the survey on purpose (full screen, neutral tint, Look
/// and Pause rather than Start and Stop): nothing here is saved, mapped or
/// sent, and it closes if a survey starts.
struct NearbyScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var nearby: NearbyModel?

    var body: some View {
        NavigationStack {
            Group {
                if let nearby {
                    NearbyList(nearby: nearby)
                        .navigationDestination(for: UUID.self) { id in
                            NearbyDetailView(nearby: nearby, id: id)
                        }
                } else {
                    Color.clear
                }
            }
            .themedList()
            .navigationTitle("Nearby Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("nearby.done")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let nearby, nearby.authorization == .allowed {
                        Button(nearby.isLooking ? "Pause" : "Look") {
                            nearby.isLooking ? nearby.pause() : nearby.look()
                        }
                        .accessibilityIdentifier("nearby.lookPause")
                    }
                }
            }
        }
        .tint(Theme.Colors.ink)
        .onAppear {
            guard nearby == nil else { return }
            let model = NearbyModel(scanner: app.makeNearbyScanner())
            nearby = model
            // Opening the screen is the choice to look, unless iOS still has to ask.
            if model.authorization == .allowed { model.look() }
        }
        .onDisappear {
            nearby?.close()
            app.idleTimer.release("nearby")
        }
        .onChange(of: nearby?.isLooking) { _, looking in
            app.idleTimer.set("nearby", held: looking == true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { nearby?.enteredBackground() }
        }
        // Never open beside a survey: close for any state but idle, also one already under way.
        .onChange(of: app.survey.state, initial: true) { _, state in
            if state != .idle { dismiss() }
        }
    }
}

private struct NearbyList: View {
    @Bindable var nearby: NearbyModel
    @State private var showingGuide = false

    var body: some View {
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        NearbySourceLabel()
                        Text("This list is live and stays on this iPhone. It isn't saved, mapped, or sent anywhere. iPhones hide Bluetooth addresses, so a device that changes its address shows up again as a new row.")
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("nearby.intro")
                }
                NearbyStatusSection(nearby: nearby)
                if !nearby.devices.isEmpty {
                    Section {
                        Picker("Sort", selection: $nearby.sort) {
                            Text("Signal").tag(NearbySort.signal)
                            Text("Recently heard").tag(NearbySort.recent)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("nearby.sort")
                        ForEach(nearby.devices) { device in
                            NavigationLink(value: device.id) {
                                NearbyRowView(device: device)
                            }
                            .accessibilityIdentifier("nearby.device")
                        }
                    } header: {
                        Text(DataFormat.count(nearby.devices.count, "device"))
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("What an NS Scout adds")
                            .font(Theme.Fonts.sectionTitle)
                            .foregroundStyle(Theme.Colors.ink)
                        ForEach(Self.scoutPoints, id: \.self) { point in
                            Label(point, systemImage: "checkmark")
                                .font(Theme.Fonts.body)
                                .foregroundStyle(Theme.Colors.ink2)
                        }
                        Button("What's an NS Scout?") { showingGuide = true }
                            .buttonStyle(.bordered)
                            .padding(.top, Theme.Spacing.xs)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityIdentifier("nearby.scoutCard")
                }
            }
            .panelRows()
        }
        .listStyle(.insetGrouped)
        .sheet(isPresented: $showingGuide) { ScoutGuideView() }
    }

    static let scoutPoints = [
        "Real device addresses, and whether each is fixed or randomized",
        "The same fixed-address device recognized across surveys and your team",
        "Keeps listening with your iPhone locked or in a pocket",
        "Wi-Fi networks and devices",
        "Listens without asking nearby devices for anything",
    ]
}

/// "Heard by this iPhone": where everything on these screens comes from.
struct NearbySourceLabel: View {
    var body: some View {
        Label("Heard by this iPhone", systemImage: "iphone")
            .font(Theme.Fonts.label)
            .foregroundStyle(Theme.Colors.ink2)
    }
}

/// Permission, radio and listening states, each with its fix.
private struct NearbyStatusSection: View {
    let nearby: NearbyModel

    var body: some View {
        if let status {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(status.message)
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let action = status.action {
                        Button(action.title, action: action.run)
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityIdentifier("nearby.status")
            }
        } else if nearby.isLooking && nearby.devices.isEmpty {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let waited = nearby.lookingSince.map { context.date.timeIntervalSince($0) } ?? 0
                    Text(waited < 10
                         ? "Listening. Devices appear as this iPhone hears them."
                         : "Nothing heard yet. Some devices, like many beacons, are hidden from iPhone apps.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                .accessibilityIdentifier("nearby.status")
            }
        }
    }

    private struct Status {
        struct Action {
            let title: String
            let run: () -> Void
        }

        let message: String
        var action: Action?
    }

    private var status: Status? {
        switch nearby.authorization {
        case .denied, .restricted:
            return Status(message: "Bluetooth is off for Network Survey. Turn it on in Settings to see nearby devices and to connect an NS Scout.",
                          action: .init(title: "Open Settings") { AccessModel.openAppSettings() })
        case .notDetermined where !nearby.isLooking:
            return Status(message: "To list nearby devices, Network Survey needs Bluetooth. Your iPhone may briefly ask devices for their names.",
                          action: .init(title: "Continue") { nearby.look() })
        default:
            break
        }
        switch nearby.radio {
        case .unauthorized:
            return Status(message: "Bluetooth is off for Network Survey. Turn it on in Settings to see nearby devices and to connect an NS Scout.",
                          action: .init(title: "Open Settings") { AccessModel.openAppSettings() })
        case .poweredOff:
            return Status(message: "Turn on Bluetooth to see nearby devices.")
        case .unsupported:
            return Status(message: "Bluetooth is not available on this device.")
        default:
            break
        }
        if nearby.pausedByBackground {
            return Status(message: "Paused while Network Survey was in the background. iPhones only let apps look for nearby devices while they're open.",
                          action: .init(title: "Look again") { nearby.look() })
        }
        if !nearby.isLooking && nearby.authorization == .allowed {
            return Status(message: "Paused. The list keeps what was heard until you close it.",
                          action: .init(title: "Look again") { nearby.look() })
        }
        return nil
    }
}

struct NearbyRowView: View {
    let device: NearbyDevice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(device.name ?? "Unnamed device")
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(device.name == nil ? Theme.Colors.ink2 : Theme.Colors.ink)
                    .lineLimit(1)
                if let tag = NearbyFormat.tag(device) {
                    TagPill(text: tag, color: Theme.Colors.ink2)
                }
            }
            Spacer(minLength: Theme.Spacing.s)
            SignalColumn(rssi: device.rssi, lastSeen: device.lastHeard)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

nonisolated enum NearbyFormat {
    /// "NS Scout" for a Scout (not connected, so advertising), else the
    /// company, else the first named service, for the row's one tag.
    static func tag(_ device: NearbyDevice) -> String? {
        if device.serviceUUIDs.contains(where: { $0.caseInsensitiveCompare(BoardGATT.serviceUUID) == .orderedSame }) {
            return "NS Scout"
        }
        if let company = device.companyID {
            return BLECompanies.name(for: company) ?? BLECompanies.hexID(company)
        }
        return (device.serviceUUIDs + device.serviceDataUUIDs).lazy.compactMap(BLEServiceUUIDs.name(forUUID:)).first
    }

    static func company(_ id: Int) -> String {
        BLECompanies.name(for: id).map { "\($0) (\(BLECompanies.hexID(id)))" } ?? BLECompanies.hexID(id)
    }
}
