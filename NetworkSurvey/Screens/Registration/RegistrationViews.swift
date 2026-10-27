import AVFoundation
import Destinations
import SwiftUI

/// Scan a registration QR code (with a paste fallback), confirm, then show
/// the result.
struct RegistrationScanSheet: View {
    @Environment(RegistrationModel.self) private var registration
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var camera = CameraAccess.unknown

    enum CameraAccess { case unknown, allowed, denied }

    var body: some View {
        NavigationStack {
            Group {
                if registration.phase == .registered, let current = registration.registration {
                    RegistrationSuccessContent(current: current) { dismiss() }
                } else if let link = registration.pendingLink {
                    RegistrationConfirmContent(link: link)
                } else {
                    scanner
                }
            }
            .screenBackground()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if registration.phase != .registered {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .registrationSuccessFeedback(registration)
        .onAppear { registration.beginScanning() }
        .task { camera = await Self.requestCamera() }
        .onDisappear { registration.endScanning() }
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
            // A verbatim prompt: a URL in a string literal is drawn as a link.
            TextField("Registration link", text: $text, prompt: Text(verbatim: "Paste or type the registration link"))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(submit)
                .accessibilityIdentifier("registration.link")
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Use", action: submit)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("registration.use")
            }
        }
    }

    private func submit() {
        if registration.receive(text) { text = "" }
    }
}

/// Shows the workspace from a link and registers on confirmation. The sheet
/// around it switches to `RegistrationSuccessContent` once it succeeds.
struct RegistrationConfirmContent: View {
    let link: NSAnalyticsLink

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
    }
}

/// The end of registration: a clear result and what happens next, so the
/// sheet never just closes (or falls back to the scanner) without a word.
struct RegistrationSuccessContent: View {
    let current: NSAnalyticsRegistration
    let onDone: () -> Void

    @State private var appeared = false

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer(minLength: 0)
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.Colors.green)
                    .symbolEffect(.bounce, value: appeared)
                    .accessibilityHidden(true)
                Text("Connected")
                    .font(Theme.Fonts.screenTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Text("This phone is registered with \(Text(current.workspaceName ?? "your workspace").bold()).")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink)
                    .multilineTextAlignment(.center)
                Text(current.apiURL.host() ?? current.apiURL.absoluteString)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("registration.success")
            Text("Uploading to NS Analytics is now on. Records upload while you survey and when a survey stops. You can change this any time in Settings > NS Analytics.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Done", action: onDone)
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("registration.done")
        }
        .padding(Theme.Spacing.screenGutter)
        .navigationTitle("NS Analytics")
        .onAppear { appeared = true }
    }
}

extension View {
    /// A success haptic when registration completes.
    func registrationSuccessFeedback(_ registration: RegistrationModel) -> some View {
        sensoryFeedback(.success, trigger: registration.phase) { _, phase in phase == .registered }
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
                    Group {
                        if registration.phase == .registered, let current = registration.registration {
                            RegistrationSuccessContent(current: current) { registration.pendingLink = nil }
                        } else {
                            RegistrationConfirmContent(link: link)
                        }
                    }
                    .screenBackground()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if registration.phase != .registered {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { registration.pendingLink = nil }
                            }
                        }
                    }
                }
                .registrationSuccessFeedback(registration)
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
