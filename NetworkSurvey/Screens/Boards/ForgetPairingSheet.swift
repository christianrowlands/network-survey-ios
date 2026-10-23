import BoardKit
import SwiftUI

/// Walks the user through Forget This Device in Settings > Bluetooth, the one
/// step iOS does not let an app do. Needed when a Scout lost this iPhone's
/// pairing (reinstalled, erased, or paired with another phone) while iOS still
/// holds its half. When `reconnect` is on, the Scout is connected again as
/// soon as the user comes back from Settings.
struct ForgetPairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    let board: BoardID
    /// The advertised name, as Settings > Bluetooth lists it ("NS-1A2B").
    let name: String
    var reconnect = true

    /// Open Settings was tapped; the next return to the app reconnects.
    @State private var openedSettings = false
    @State private var awaitingReturn = false
    @State private var phase = Phase.instructions
    @State private var connectTask: Task<Void, Never>?

    enum Phase: Equatable {
        case instructions, connecting, connected
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Text(reconnect
                         ? "\(name) no longer has this iPhone's pairing. It was reinstalled, erased or paired with another phone, but iOS still remembers the old pairing. iOS doesn't let apps remove it, so it takes a quick trip to Settings."
                         : "\(name) erased its pairings. Before it can pair with this iPhone again, iOS has to forget the old pairing too. You can do this now or whenever you next want to use it.")
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Panel {
                        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                            GuideStep(1, "Open the Settings app and tap Bluetooth.")
                            GuideStep(2, "Under My Devices, find \(name).")
                            GuideStep(3, "Tap the info button (i) next to it.")
                            GuideStep(4, "Tap Forget This Device, then confirm.")
                            GuideStep(5, reconnect
                                      ? "Come back to Network Survey. It connects again on its own, and iOS asks you to tap Pair."
                                      : "Next time you connect \(name), tap Pair when iOS asks.")
                        }
                    }
                    Button {
                        openedSettings = true
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Open Settings", systemImage: "gear")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("forgetPairing.openSettings")
                    Text("Settings opens on Network Survey's page. Tap the back button at the top left until you reach Settings, then tap Bluetooth.")
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                    if reconnect { status }
                }
                .padding(Theme.Spacing.screenGutter)
                .frame(maxWidth: Theme.Spacing.contentMaxWidth)
                .frame(maxWidth: .infinity)
            }
            .screenBackground()
            .navigationTitle("Forget \(name) in iOS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .connected ? "Done" : "Close") { dismiss() }
                }
            }
        }
        .onChange(of: scenePhase) { _, now in
            if now == .background, openedSettings { awaitingReturn = true }
            guard now == .active, awaitingReturn, reconnect, phase != .connecting, phase != .connected else { return }
            openedSettings = false
            awaitingReturn = false
            startConnect()
        }
        // The Scout has to be heard again to connect after iOS forgets it.
        .task { if reconnect { await model.boardManager.startScanning() } }
        .onDisappear {
            connectTask?.cancel()
            if reconnect { Task { await model.boardManager.stopScanning() } }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .instructions:
            Button("I've done this, connect now") { startConnect() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        case .connecting:
            HStack(spacing: Theme.Spacing.s) {
                ProgressView()
                Text("Connecting. Tap Pair when iOS asks.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .frame(maxWidth: .infinity)
        case .connected:
            Label("\(name) is connected again", systemImage: "checkmark.circle.fill")
                .font(Theme.Fonts.rowTitle)
                .foregroundStyle(Theme.Colors.green)
                .frame(maxWidth: .infinity)
        case .failed(let message):
            VStack(spacing: Theme.Spacing.s) {
                Text(message)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.amberText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { startConnect() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func startConnect() {
        connectTask?.cancel()
        connectTask = Task { await connect() }
    }

    private func connect() async {
        phase = .connecting
        let failure = await model.connect(board)
        guard !Task.isCancelled else { return }
        if let failure {
            phase = .failed(model.boardManager.boards[board]?.issue == .bondMissing
                ? "iOS still has the old pairing for \(name). Check that you chose Forget This Device for \(name), then try again."
                : failure)
        } else {
            phase = .connected
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
