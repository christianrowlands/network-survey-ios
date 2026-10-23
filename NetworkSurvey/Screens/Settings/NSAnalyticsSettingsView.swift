import SurveyCore
import SwiftUI

struct NSAnalyticsSettingsView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(RegistrationModel.self) private var registration
    @State private var scanning = false
    @State private var confirmingUnregister = false
    @State private var unregisterNote: String?

    /// Minutes between uploads while surveying; 0 uploads only at stop.
    private static let schedules = [5, 15, 30, 60, 0]

    var body: some View {
        Form {
            Group {
                if let current = registration.registration {
                    Section {
                        LabeledContent("Workspace", value: current.workspaceName ?? "Unnamed workspace")
                        LabeledContent("Server") {
                            Text(current.apiURL.host() ?? current.apiURL.absoluteString)
                                .font(Theme.Fonts.mono)
                        }
                        Label("Registered", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Colors.green)
                            .accessibilityIdentifier("nsa.registered")
                    }
                    Section {
                        Toggle("Upload to NS Analytics", isOn: settings.binding(Settings.destinationNSAnalytics))
                        Picker("Upload", selection: settings.binding(Settings.nsAnalyticsUploadIntervalMinutes)) {
                            ForEach(Self.schedules, id: \.self) { minutes in
                                Text(Self.scheduleName(minutes)).tag(minutes)
                            }
                        }
                    } footer: {
                        Text("Uploads also run when a survey stops and finish in the background. Records without a location are not uploaded.")
                    }
                    Section {
                        Toggle("Upload probe requests", isOn: settings.binding(Settings.nsAnalyticsUploadProbeRecords))
                        Toggle("Upload client records", isOn: settings.binding(Settings.nsAnalyticsUploadClientRecords))
                    } header: {
                        Text("Experimental")
                    } footer: {
                        AppliesNextSurveyFooter(extra: "NS Analytics does not store these record types yet and skips them.")
                    }
                    Section {
                        Button("Register with another workspace") { scanning = true }
                        Button("Unregister this phone", role: .destructive) { confirmingUnregister = true }
                            .accessibilityIdentifier("nsa.unregister")
                    } footer: {
                        if let unregisterNote { Text(unregisterNote) }
                    }
                } else {
                    Section {
                        Text("Upload surveys to an NS Analytics workspace to see coverage from every phone on one map. A workspace admin creates a registration QR code or link in NS Analytics.")
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                    Section {
                        Button {
                            scanning = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                        .accessibilityIdentifier("nsa.scan")
                    } footer: {
                        if let unregisterNote { Text(unregisterNote) }
                    }
                    Section {
                        RegistrationLinkField()
                        PasteLinkButton()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } header: {
                        Text("Registration link")
                    } footer: {
                        Text("Copy the registration link in NS Analytics first, then tap Paste, or enter it above.")
                    }
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("NS Analytics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $scanning) {
            RegistrationScanSheet()
                .environment(registration)
        }
        .confirmationDialog("Unregister this phone?", isPresented: $confirmingUnregister, titleVisibility: .visible) {
            Button("Unregister", role: .destructive) {
                Task {
                    let confirmed = await registration.unregister()
                    unregisterNote = confirmed
                        ? "This phone is no longer registered."
                        : "Removed on this phone, but NS Analytics could not be reached. A workspace admin can remove the phone there."
                }
            }
        } message: {
            Text("Uploads stop. Records not uploaded yet stay on this phone and upload after you register again.")
        }
    }

    static func scheduleName(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Only when a survey stops"
        case 60: "Every hour"
        default: "Every \(minutes) minutes"
        }
    }
}
