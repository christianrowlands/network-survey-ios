import SurveyCore
import SwiftUI

struct SettingsScreen: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(RegistrationModel.self) private var registration
    @Environment(AppModel.self) private var app
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    Section("Where the data goes") {
                        NavigationLink(value: SettingsRoute.logFiles) {
                            SettingsLinkLabel(title: "Files", symbol: "doc.text", detail: filesDetail)
                        }
                        .accessibilityIdentifier("settings.files")
                        NavigationLink(value: SettingsRoute.mqtt) {
                            SettingsLinkLabel(title: "MQTT", symbol: "antenna.radiowaves.left.and.right",
                                              detail: streamDetail(Settings.destinationMQTT, host: Settings.mqttHost))
                        }
                        .accessibilityIdentifier("settings.mqtt")
                        NavigationLink(value: SettingsRoute.grpc) {
                            SettingsLinkLabel(title: "gRPC", symbol: "server.rack",
                                              detail: streamDetail(Settings.destinationGRPC, host: Settings.grpcHost))
                        }
                        .accessibilityIdentifier("settings.grpc")
                        NavigationLink(value: SettingsRoute.nsAnalytics) {
                            SettingsLinkLabel(title: "NS Analytics", symbol: "chart.bar", detail: nsAnalyticsDetail)
                        }
                        .accessibilityIdentifier("settings.nsAnalytics")
                    }
                    Section("Privacy") {
                        NavigationLink { PrivacyZonesView() } label: {
                            SettingsLinkLabel(title: "Privacy zones", symbol: "hand.raised",
                                              detail: countText(settings[Settings.privacyZones].count))
                        }
                        .accessibilityIdentifier("settings.zones")
                        NavigationLink { IgnoreListView() } label: {
                            SettingsLinkLabel(title: "Ignore list", symbol: "eye.slash",
                                              detail: countText(settings[Settings.ignoreList].count))
                        }
                        .accessibilityIdentifier("settings.ignoreList")
                    }
                    Section {
                        Picker(selection: settings.binding(Settings.locationSource)) {
                            Text("Phone").tag(LocationSourcePreference.phone)
                            Text("Board GPS").tag(LocationSourcePreference.board)
                        } label: {
                            Label("Location", systemImage: "location")
                        }
                        if let notice = LocationNotice(app.access.location) {
                            InfoRow(symbol: notice.symbol, symbolColor: notice.level.color, title: notice.title,
                                    detail: [notice.detail]) {
                                if let action = notice.action {
                                    Button(action.title) { Task { await app.access.perform(action) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("settings.locationNotice")
                        }
                        Picker(selection: settings.binding(Settings.units)) {
                            Text("Metric").tag(DisplayUnits.metric)
                            Text("Imperial").tag(DisplayUnits.imperial)
                        } label: {
                            Label("Units", systemImage: "ruler")
                        }
                        NavigationLink { DeviceNameView() } label: {
                            SettingsLinkLabel(title: "Device name", symbol: "iphone", detail: deviceNameDetail)
                        }
                    } header: {
                        Text("This phone")
                    } footer: {
                        Text(settings[Settings.locationSource] == .phone
                            ? "Records use the phone's location. A board GPS fills in when the phone has no recent, accurate fix."
                            : "Records use a board GPS when one has a fix, and the phone's location otherwise.")
                    }
                    #if DEBUG
                    Section("Developer") {
                        NavigationLink {
                            DebugRecordsView()
                        } label: {
                            Label("Live records (demo board)", systemImage: "list.bullet.rectangle")
                        }
                        .accessibilityIdentifier("settings.debugRecords")
                    }
                    #endif
                    Section {
                        NavigationLink { AboutView() } label: {
                            SettingsLinkLabel(title: "About", symbol: "info.circle", detail: "Version \(Bundle.main.shortVersion)")
                        }
                        NavigationLink { LicensesView() } label: {
                            Label("Open-source licenses", systemImage: "doc.plaintext")
                        }
                    }
                }
                .panelRows()
            }
            .themedList()
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .logFiles: FileSettingsView()
                case .mqtt: MQTTSettingsView()
                case .grpc: GRPCSettingsView()
                case .nsAnalytics: NSAnalyticsSettingsView()
                }
            }
            .onChange(of: app.settingsRoute, initial: true) { _, route in
                // Another screen asked for a page ("Set up" on a destination).
                guard let route else { return }
                path = [route]
                app.settingsRoute = nil
            }
        }
    }

    private var filesDetail: String {
        guard settings[Settings.destinationLogFiles] else { return "Off" }
        return settings[Settings.logWigleCSV] ? "CSV, WiGLE" : "CSV"
    }

    private func streamDetail(_ enabled: SettingKey<Bool>, host: SettingKey<String>) -> String {
        guard settings[enabled] else { return "Off" }
        let value = settings[host]
        return value.isEmpty ? "No host" : value
    }

    private var nsAnalyticsDetail: String {
        guard let current = registration.registration else { return "Not registered" }
        guard settings[Settings.destinationNSAnalytics] else { return "Off" }
        return current.workspaceName ?? "Registered"
    }

    private var deviceNameDetail: String {
        let name = settings[Settings.deviceName]
        return name.isEmpty ? DeviceIdentity.defaultName(installID: app.identity.installID) : name
    }

    private func countText(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }
}

private struct DeviceNameView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("Device name", text: settings.binding(Settings.deviceName), prompt: Text(DeviceIdentity.defaultName(installID: app.identity.installID)))
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.deviceName")
                } footer: {
                    Text("Sent as the device name with MQTT and gRPC records so you can tell phones apart. Leave empty to use the name shown in gray.")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("Device name")
        .navigationBarTitleDisplayMode(.inline)
    }
}
