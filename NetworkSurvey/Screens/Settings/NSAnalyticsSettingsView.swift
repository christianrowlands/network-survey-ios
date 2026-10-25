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
                        Button("Register with another workspace") { scanning = true }
                        Button("Unregister this phone", role: .destructive) { confirmingUnregister = true }
                            .accessibilityIdentifier("nsa.unregister")
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
                    } footer: {
                        if let unregisterNote { Text(unregisterNote) }
                    }
                } else {
                    NSAnalyticsIntroSections(scanning: $scanning, note: unregisterNote)
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
    }

    static func scheduleName(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Only when a survey stops"
        case 60: "Every hour"
        default: "Every \(minutes) minutes"
        }
    }
}
