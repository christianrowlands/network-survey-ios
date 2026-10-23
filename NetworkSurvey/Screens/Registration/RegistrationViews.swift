import AVFoundation
import Destinations
import SwiftUI

/// Scan a registration QR code (with a paste fallback), then confirm.
struct RegistrationScanSheet: View {
    @Environment(RegistrationModel.self) private var registration
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var camera = CameraAccess.unknown

    enum CameraAccess { case unknown, allowed, denied }

    var body: some View {
        NavigationStack {
            Group {
                if let link = registration.pendingLink {
                    RegistrationConfirmContent(link: link) { dismiss() }
                } else {
                    scanner
                }
            }
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        registration.pendingLink = nil
                        dismiss()
                    }
                }
            }
        }
        .onAppear { registration.isScanning = true }
        .task { camera = await Self.requestCamera() }
        .onDisappear { registration.isScanning = false }
    }

    private var scanner: some View {
        VStack(spacing: Theme.Spacing.l) {
            if camera == .denied {
                ContentUnavailableView {
                    Label("Camera access is off", systemImage: "camera")
                } description: {
                    Text("Allow camera access for Network Survey in Settings to scan the code, or paste the registration link instead.")
                } actions: {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } else if camera == .unknown {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if QRScannerView.isAvailable {
                QRScannerView { code in registration.receive(code) }
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    .accessibilityLabel("Camera viewfinder")
                Text("Point the camera at the registration QR code from your NS Analytics workspace.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .multilineTextAlignment(.center)
            } else {
                ContentUnavailableView(
                    "Camera scanning not available",
                    systemImage: "qrcode.viewfinder",
                    description: Text("Copy the registration link from your NS Analytics workspace and paste it instead.")
                )
            }
            if let error = registration.linkError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.amberText)
            }
            PasteLinkButton()
        }
        .padding(Theme.Spacing.screenGutter)
        .navigationTitle("Scan QR code")
    }
}

/// Pastes a registration link without the clipboard permission prompt.
struct PasteLinkButton: View {
    @Environment(RegistrationModel.self) private var registration

    var body: some View {
        PasteButton(payloadType: String.self) { strings in
            guard let text = strings.first else { return }
            Task { @MainActor in registration.receive(text) }
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .tint(Theme.Colors.accent)
        .accessibilityIdentifier("registration.paste")
    }
}

/// Type or paste (from the keyboard menu) a registration link.
struct RegistrationLinkField: View {
    @Environment(RegistrationModel.self) private var registration
    @State private var text = ""

    var body: some View {
        HStack {
            TextField("https://networksurvey.app/app/register?...", text: $text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityLabel("Registration link")
                .accessibilityIdentifier("registration.link")
            Button("Use", action: submit)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        if registration.receive(text) { text = "" }
    }
}

/// Shows the workspace from a link and registers on confirmation.
struct RegistrationConfirmContent: View {
    let link: NSAnalyticsLink
    let onDone: () -> Void

    @Environment(RegistrationModel.self) private var registration

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Overline(text: "NS Analytics workspace")
                Text(link.workspaceName ?? "Unnamed workspace")
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Text(link.apiURL.host() ?? link.apiURL.absoluteString)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Text("Registering lets this phone upload survey data to the workspace: Wi-Fi access points, Bluetooth devices and device status, each with its location. You can unregister at any time in Settings.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
            if case .failed(let message) = registration.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.red)
            }
            Spacer(minLength: 0)
            Button {
                Task { await registration.register(link) }
            } label: {
                if registration.phase == .registering {
                    ProgressView().tint(Theme.Colors.onAccent)
                } else {
                    Text(registration.registration == nil ? "Register this phone" : "Switch to this workspace")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(registration.phase == .registering)
            .accessibilityIdentifier("registration.confirm")
        }
        .padding(Theme.Spacing.screenGutter)
        .navigationTitle("Register")
        .onChange(of: registration.phase) { _, phase in
            if phase == .registered { onDone() }
        }
    }
}

/// Picks up registration links the app was opened with (the universal link
/// lands in `AppModel.pendingRegistrationLink`) and shows the confirm sheet.
struct RegistrationLinkHandling: ViewModifier {
    let registration: RegistrationModel
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .onChange(of: app.pendingRegistrationLink, initial: true) { _, url in
                guard let url else { return }
                app.pendingRegistrationLink = nil
                registration.receive(url)
            }
            .sheet(item: Binding(
                get: { registration.isScanning ? nil : registration.pendingLink },
                set: { if $0 == nil && !registration.isScanning { registration.pendingLink = nil } }
            )) { link in
                NavigationStack {
                    RegistrationConfirmContent(link: link) { registration.pendingLink = nil }
                        .screenBackground()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { registration.pendingLink = nil }
                            }
                        }
                }
                .environment(registration)
                .presentationDetents([.medium, .large])
            }
            .alert("Registration link", isPresented: Binding(
                get: { registration.linkError != nil && registration.pendingLink == nil && !registration.isScanning },
                set: { if !$0 { registration.linkError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(registration.linkError ?? "")
            }
    }
}

extension RegistrationScanSheet {
    /// Asks for the camera the first time; denied or restricted means the
    /// scanner cannot run.
    static func requestCamera() async -> CameraAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
        default: return .denied
        }
    }
}

extension NSAnalyticsLink: @retroactive Identifiable {
    public var id: String { token + workspaceID }
}
