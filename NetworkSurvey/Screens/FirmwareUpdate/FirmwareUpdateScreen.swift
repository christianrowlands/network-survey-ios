import BoardKit
import BoardProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Updates one board's firmware: the signed official release, or a file the
/// user picks (unsigned only after an explicit warning). The app must stay in
/// the foreground with the phone near the board while the image transfers.
struct FirmwareUpdateScreen: View {
    let boardID: BoardID
    @Environment(AppModel.self) private var app
    @State private var model: FirmwareUpdateModel?

    var body: some View {
        Group {
            if let model {
                FirmwareUpdateContent(model: model)
            } else {
                Color.clear.screenBackground()
            }
        }
        .task {
            if model == nil {
                model = FirmwareUpdateModel(boardID: boardID, manager: app.boardManager, isDemo: app.isDemo(boardID))
            }
        }
    }
}

private struct FirmwareUpdateContent: View {
    @Bindable var model: FirmwareUpdateModel
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var confirmingCancel = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.panelGap) {
                boardPanel
                if let blocker = model.blocker, !model.isInstalling, !isFinished {
                    NoticePanel(symbol: "exclamationmark.triangle", title: "Can't update now", message: blocker) { EmptyView() }
                }
                stagePanel
            }
            .padding(.horizontal, Theme.Spacing.screenGutter)
            .padding(.vertical, Theme.Spacing.l)
            .frame(maxWidth: Theme.Spacing.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("Firmware update")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isInstalling)
        .toolbar {
            if model.isInstalling {
                ToolbarItem(placement: .cancellationAction) {
                    // After OtaEnd the board may already be switching images; nothing can stop that.
                    Button("Cancel") { confirmingCancel = true }
                        .disabled(!model.canCancel)
                        .accessibilityIdentifier("firmware.cancel")
                }
            }
        }
        .confirmationDialog("Cancel the update?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button("Cancel update", role: .destructive) { model.cancel() }
                .disabled(!model.canCancel)
            Button("Keep updating", role: .cancel) {}
        } message: {
            Text("The transfer stops and the board keeps its current firmware.")
        }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.loadFile(urls: urls) }
        }
        .onChange(of: model.isInstalling, initial: true) { _, installing in
            app.idleTimer.set("firmwareUpdate", held: installing)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.noteBackground() }
        }
        .onDisappear { app.idleTimer.release("firmwareUpdate") }
    }

    private var isFinished: Bool {
        if case .done = model.stage { true } else { false }
    }

    // MARK: Board

    private var boardPanel: some View {
        Panel {
            Overline(text: "Board")
            Text(model.info?.modelName.nonEmpty ?? "Board")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.ink)
            if let info = model.info {
                LabeledContent("Installed firmware", value: info.firmwareVersion.nonEmpty ?? "unknown")
                LabeledContent("Chip", value: info.chip.displayName)
            }
            if case .incompatible(let reason)? = model.board?.compatibility {
                Text(reason)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.amberText)
            }
        }
        .font(Theme.Fonts.body)
    }

    // MARK: Stages

    @ViewBuilder private var stagePanel: some View {
        switch model.stage {
        case .start:
            startPanel
        case .checking:
            busyPanel("Checking for updates")
        case .offer(let offer):
            offerPanel(offer)
        case .downloading(let offer):
            busyPanel("Downloading firmware \(offer.version)")
        case .ready(let package):
            readyPanel(package)
        case .installing(let phase):
            installingPanel(phase)
        case .done(let result):
            donePanel(result)
        case .failed(let error):
            failedPanel(error)
        }
    }

    private var startPanel: some View {
        Panel {
            Button("Check for update") { Task { await model.check() } }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("firmware.check")
            Button("Install from file...") { importing = true }
                .frame(maxWidth: .infinity, minHeight: Theme.Spacing.touchTarget)
                .accessibilityIdentifier("firmware.fromFile")
            Text("Choose the app image (.bin). To install a signed build, pick its .sig file too.")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.ink2)
        }
        .disabled(model.blocker != nil)
    }

    private func busyPanel(_ text: String) -> some View {
        Panel {
            HStack(spacing: Theme.Spacing.m) {
                ProgressView()
                Text(text).foregroundStyle(Theme.Colors.ink2)
            }
            .frame(minHeight: Theme.Spacing.touchTarget)
        }
    }

    private func offerPanel(_ offer: FirmwareOffer) -> some View {
        Panel {
            Overline(text: "Official release")
            Text(offerHeadline(offer))
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.ink)
            if offer.signer.isDevelopment {
                TagPill(text: "Signed with the development key", color: Theme.Colors.amber)
            }
            if let newer = offer.newerVersionSeen {
                Text("This phone has seen a newer release (\(newer)) before. The release server may be out of date.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.amberText)
            }
            keepNearWarning
            Button(installLabel(offer)) { Task { await model.downloadAndInstall(offer) } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.blocker != nil)
                .accessibilityIdentifier("firmware.install")
            Button("Back") { model.reset() }
                .frame(maxWidth: .infinity, minHeight: Theme.Spacing.touchTarget)
        }
    }

    private func readyPanel(_ package: FirmwarePackage) -> some View {
        Panel {
            Overline(text: package.isRelease ? "Official release" : "Firmware file")
            Text("Version \(package.version ?? "unknown"), \(ByteCountFormatter.string(fromByteCount: Int64(package.image.count), countStyle: .file))")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.ink)
            switch package.origin {
            case .signedFile(let signer, let development), .release(let signer, let development):
                TagPill(text: development ? "Signed: \(signer)" : "Signed", color: development ? Theme.Colors.amber : Theme.Colors.green)
            case .unsignedFile:
                NoticePanel(
                    symbol: "exclamationmark.shield", title: "Unsigned firmware",
                    message: "This file is not signed by the Network Survey project. Only install firmware you built yourself or got from someone you trust. Bad firmware can stop the board from working until it is reflashed over USB.",
                    tone: .danger
                ) { EmptyView() }
            }
            if !package.isRelease {
                LabeledContent("Built for", value: [package.header.chipName, package.header.projectName].compactMap { $0 }.joined(separator: ", "))
                    .font(Theme.Fonts.body)
            }
            ForEach(model.consents(for: package), id: \.self) { consent in
                Toggle(consentText(consent), isOn: Binding(
                    get: { model.accepted.contains(consent) },
                    set: { if $0 { model.accepted.insert(consent) } else { model.accepted.remove(consent) } }
                ))
                .tint(consent == .unsigned ? Theme.Colors.red : Theme.Colors.accent)
                .font(Theme.Fonts.body)
                .accessibilityIdentifier("firmware.consent")
            }
            keepNearWarning
            Button("Install") { model.install(package) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.isAccepted(package) || model.blocker != nil)
                .accessibilityIdentifier("firmware.install")
            Button("Back") { model.reset() }
                .frame(maxWidth: .infinity, minHeight: Theme.Spacing.touchTarget)
        }
    }

    private func installingPanel(_ phase: FirmwareInstallPhase) -> some View {
        Panel {
            Overline(text: "Updating")
            Text(phaseText(phase))
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.ink)
            if case .transferring(let sent, let total) = phase, total > 0 {
                ProgressView(value: Double(sent), total: Double(total))
                    .tint(Theme.Colors.accent)
                Text("\(Int(Double(sent) / Double(total) * 100)) %")
                    .font(Theme.Fonts.counter)
                    .foregroundStyle(Theme.Colors.ink2)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if model.leftForeground {
                Text("Network Survey went to the background. Keep it open until the update finishes.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.amberText)
            }
            keepNearWarning
        }
        .accessibilityElement(children: .combine)
    }

    private func donePanel(_ result: FirmwareInstallResult) -> some View {
        Panel {
            Label("Firmware \(result.newVersion) installed", systemImage: "checkmark.circle.fill")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.green)
            Text("The board was on \(result.previousVersion.nonEmpty ?? "an unknown version") and restarted with the new firmware.")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink2)
            if !result.compatible {
                Text("This firmware speaks a different protocol version than this app, so the board can't survey with it. Install a matching firmware or update the app.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.amberText)
            }
        }
    }

    private func failedPanel(_ error: FirmwareUpdateError) -> some View {
        Panel {
            Label("Update not installed", systemImage: "xmark.octagon.fill")
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.red)
            Text(error.userMessage)
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.ink)
                .fixedSize(horizontal: false, vertical: true)
            if error.isResumable, let package = model.lastPackage {
                Button("Resume update") { model.install(package) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.blocker != nil)
                    .accessibilityIdentifier("firmware.resume")
                Button("Start over") { model.reset() }
                    .frame(maxWidth: .infinity, minHeight: Theme.Spacing.touchTarget)
            } else {
                Button("Start over") { model.reset() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("firmware.retry")
            }
        }
    }

    private var keepNearWarning: some View {
        Label("Keep this screen open and the phone next to the board. The update takes a few minutes.", systemImage: "iphone.radiowaves.left.and.right")
            .font(Theme.Fonts.caption)
            .foregroundStyle(Theme.Colors.ink2)
    }

    // MARK: Text

    private func offerHeadline(_ offer: FirmwareOffer) -> String {
        switch offer.comparison {
        case .newer: "Firmware \(offer.version) is available"
        case .same: "The board already runs \(offer.version), the latest release"
        case .older: "The latest release (\(offer.version)) is older than the board's firmware"
        case .unknown: "Release \(offer.version) is available (installed: \(offer.installedVersion.nonEmpty ?? "unknown"))"
        }
    }

    private func installLabel(_ offer: FirmwareOffer) -> String {
        switch offer.comparison {
        case .newer, .unknown: "Install \(offer.version)"
        case .same: "Reinstall \(offer.version)"
        case .older: "Install older \(offer.version)"
        }
    }

    private func consentText(_ consent: FirmwareConsent) -> String {
        switch consent {
        case .unsigned: "I understand, install unsigned firmware"
        case .boardModel(let model): "This firmware is built for \(model)"
        case .notNewer(.same): "Reinstall the version the board already runs"
        case .notNewer: "Install an older version than the board runs"
        case .staleRelease(let newer): "Install it although \(newer) was released"
        }
    }

    private func phaseText(_ phase: FirmwareInstallPhase) -> String {
        switch phase {
        case .connecting: "Connecting to the board"
        case .transferring: "Sending firmware"
        case .reconnecting(let attempt): "Connection lost, reconnecting (attempt \(attempt))"
        case .verifying: "The board is checking the firmware"
        case .restarting: "The board is restarting"
        case .confirming: "Checking the new version"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
