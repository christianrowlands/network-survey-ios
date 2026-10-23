import BoardKit
import SurveyCore
import SwiftUI

/// The Ready state: what is still to do, the Scouts, "What should it survey?"
/// and "Where should the data go?", then a sentence saying what Start will do.
struct SurveyReadyBody: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    let setup: SurveySetup
    let onSelectBoard: (BoardID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            StillToDoPanel()
            if !model.boardsInUse.isEmpty {
                SectionHeader(title: "Scouts", trailing: boardsTrailing)
                BoardStrip(onSelect: onSelectBoard)
            }

            SectionHeader(title: "What should it survey?", trailing: "\(setup.protocols.count) of \(SurveyProtocol.allCases.count) on")
            Grid(horizontalSpacing: Theme.Spacing.s, verticalSpacing: Theme.Spacing.s) {
                ForEach(rows, id: \.self) { row in
                    GridRow {
                        ForEach(row) { item in
                            ToggleTile(
                                title: item.title, detail: item.detail, symbol: item.symbol, color: item.color,
                                isOn: setup.protocols.contains(item)
                            ) {
                                model.settings[item.key].toggle()
                            }
                            .accessibilityIdentifier("survey.protocol.\(item.title)")
                        }
                    }
                }
            }

            SectionHeader(
                title: "Where should the data go?",
                trailing: "\(setup.activeDestinations.count) of \(SurveyDestination.allCases.count) on"
            )
            Panel {
                ForEach(Array(SurveyDestination.allCases.enumerated()), id: \.element) { index, destination in
                    if index > 0 { Divider().overlay(Theme.Colors.rule) }
                    DestinationRow(destination: destination, setup: setup)
                }
            }

            if let sentence = setup.sentence {
                Text(sentence)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .padding(.top, Theme.Spacing.xs)
                    .accessibilityIdentifier("survey.sentence")
            }
            ForEach(setup.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.amberText)
            }
        }
    }

    /// Two tiles per row, one at accessibility text sizes. Tiles in a row share a height.
    private var rows: [[SurveyProtocol]] {
        let perRow = typeSize.isAccessibilitySize ? 1 : 2
        return stride(from: 0, to: SurveyProtocol.allCases.count, by: perRow).map {
            Array(SurveyProtocol.allCases[$0..<min($0 + perRow, SurveyProtocol.allCases.count)])
        }
    }

    private var boardsTrailing: String? {
        let ready = model.boardManager.readyBoards.count
        return ready == 0 ? nil : "\(ready) connected"
    }
}

/// A destination: a switch when it is ready, otherwise Set up or Connect.
private struct DestinationRow: View {
    @Environment(AppModel.self) private var model
    let destination: SurveyDestination
    let setup: SurveySetup

    var body: some View {
        let configured = setup.configured.contains(destination)
        let unavailable = setup.unavailable[destination]
        InfoRow(
            symbol: destination.symbol, title: destination.title,
            detail: [unavailable ?? detail(configured: configured)]
        ) {
            if unavailable != nil {
                EmptyView()
            } else if configured {
                HStack(spacing: Theme.Spacing.s) {
                    if destination != .logFiles {
                        Button {
                            model.open(destination.route)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: Theme.Spacing.touchTarget, height: Theme.Spacing.touchTarget)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("\(destination.title) settings")
                    }
                    Toggle(destination.title, isOn: Binding(
                        get: { setup.destinationsOn.contains(destination) },
                        set: { model.settings[destination.key] = $0 }
                    ))
                    .labelsHidden()
                    .tint(Theme.Colors.accent)
                    .accessibilityIdentifier("survey.destination.\(destination.title)")
                }
            } else {
                Button(destination == .nsAnalytics ? "Connect" : "Set up") {
                    model.open(destination.route)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("\(destination == .nsAnalytics ? "Connect" : "Set up") \(destination.title)")
            }
        }
        .opacity(unavailable == nil ? 1 : 0.6)
    }

    private func detail(configured: Bool) -> String {
        if configured { return setup.details[destination] ?? "" }
        return destination == .nsAnalytics ? "See your surveys on a team map" : "Not set up"
    }
}

/// What stands between the user and a useful survey: Bluetooth, location, a
/// Scout, and records still waiting to upload from earlier surveys.
private struct StillToDoPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showingGuide = false

    var body: some View {
        let items = self.items
        if !items.isEmpty {
            SectionHeader(title: "Still to do")
            Panel {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Theme.Colors.rule) }
                    InfoRow(symbol: item.symbol, symbolColor: item.level.color, title: item.title, detail: item.detail) {
                        if let action = item.action {
                            Button(action.title) { action.run() }
                                .buttonStyle(.bordered)
                                .disabled(action.disabled)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    if item.id == "board" {
                        Button {
                            showingGuide = true
                        } label: {
                            Label("Don't have one? See what an NS Scout is and how to get one.", systemImage: "questionmark.circle")
                                .font(Theme.Fonts.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .padding(.leading, 24 + Theme.Spacing.m)
                        .padding(.bottom, Theme.Spacing.s)
                        .accessibilityIdentifier("survey.scoutGuide")
                    }
                }
            }
            .accessibilityIdentifier("survey.stillToDo")
            .sheet(isPresented: $showingGuide) { ScoutGuideView() }
        }
    }

    private struct Item: Identifiable {
        struct Action {
            let title: String
            var disabled = false
            let run: () -> Void
        }

        let id: String
        let symbol: String
        let level: StatusLevel
        let title: String
        let detail: [String]
        var action: Action?
    }

    private var items: [Item] {
        var items: [Item] = []
        let access = model.access
        switch access.bluetooth {
        case .off:
            items.append(Item(id: "bt-off", symbol: "bolt.horizontal.circle", level: .failing, title: "Bluetooth is off",
                              detail: ["Turn it on in Control Center to reach your Scout."]))
        case .denied, .restricted:
            items.append(Item(id: "bt-denied", symbol: "bolt.horizontal.circle", level: .failing,
                              title: "Bluetooth access is off",
                              detail: ["Network Survey needs Bluetooth to talk to your Scout."],
                              action: .init(title: "Open Settings") { AccessModel.openAppSettings() }))
        case .unsupported:
            items.append(Item(id: "bt-unsupported", symbol: "bolt.horizontal.circle", level: .failing,
                              title: "Bluetooth is not available", detail: ["This device can't connect to a Scout."]))
        case .notDetermined, .ready:
            break
        }
        if model.boardManager.readyBoards.isEmpty && model.boardsInUse.isEmpty {
            items.append(Item(id: "board", symbol: "sensor", level: .pending, title: "Connect your NS Scout",
                              detail: ["The Scout listens for Wi-Fi and Bluetooth. Plug it in and hold it next to your iPhone, or try the demo Scout."],
                              action: .init(title: "Find Scouts") { model.openBoards() }))
        }
        if let notice = LocationNotice(access.location) {
            items.append(Item(id: notice.id, symbol: notice.symbol, level: notice.level, title: notice.title,
                              detail: [notice.detail],
                              action: notice.action.map { action in
                                  .init(title: action.title) { Task { await access.perform(action) } }
                              }))
        }
        if let state = model.nsAnalyticsState, state.pending > 0 {
            var detail = ["Waiting for NS Analytics"]
            if let last = state.lastUploadAt { detail.append("Last upload \(last.formatted(date: .abbreviated, time: .shortened))") }
            if let paused = state.pausedUntil, paused > Date() {
                detail.append("Paused until \(paused.formatted(date: .abbreviated, time: .shortened))")
            }
            items.append(Item(id: "upload", symbol: "icloud.and.arrow.up", level: .held,
                              title: "\(state.pending.formatted()) \(state.pending == 1 ? "record" : "records") to upload",
                              detail: detail,
                              action: .init(title: model.isUploading ? "Uploading" : "Upload now", disabled: model.isUploading) {
                                  Task { await model.uploadNow() }
                              }))
        }
        return items
    }
}
