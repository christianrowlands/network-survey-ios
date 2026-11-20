import SurveyCore
import SwiftUI

/// Adds a watched network, or edits one: a display name and what to match,
/// the network name, one access point, or both together. Shown in a sheet,
/// wrapped in a NavigationStack.
struct WatchlistEntryEditor: View {
    enum Mode {
        /// Prefilled from an access point; `turnOnAlerts` when adding from a
        /// detail screen, where the alerts switch is out of sight.
        case add(ssid: String, bssid: String, turnOnAlerts: Bool)
        case edit(WatchlistEntry)
    }

    enum MatchBy: Hashable {
        case name, accessPoint, both
    }

    let mode: Mode

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var ssid: String
    @State private var bssid: String
    @State private var matchBy: MatchBy
    @State private var problem: String?
    @State private var saving = false

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .add(let ssid, let bssid, _):
            _label = State(initialValue: "")
            _ssid = State(initialValue: ssid)
            _bssid = State(initialValue: bssid)
            _matchBy = State(initialValue: ssid.isEmpty && !bssid.isEmpty ? .accessPoint : .name)
        case .edit(let entry):
            let isDefault = entry.label == WatchlistMatcher.resolveLabel(nil, ssid: entry.ssid, bssid: entry.bssid)
            _label = State(initialValue: isDefault ? "" : entry.label)
            _ssid = State(initialValue: entry.ssid ?? "")
            _bssid = State(initialValue: entry.bssid ?? "")
            _matchBy = State(initialValue: entry.ssid != nil && entry.bssid != nil ? .both : entry.ssid == nil ? .accessPoint : .name)
        }
    }

    var body: some View {
        Form {
            Group {
                Section {
                    TextField("Display name", text: $label, prompt: Text(defaultLabel.isEmpty ? "Display name" : defaultLabel))
                        .accessibilityIdentifier("watchlist.label")
                } footer: {
                    Text("Shown in notifications and History. Leave empty to use the network name.")
                }
                Section {
                    Picker("Match by", selection: $matchBy) {
                        Text("Network name").tag(MatchBy.name)
                        Text("Access point").tag(MatchBy.accessPoint)
                        Text("Both").tag(MatchBy.both)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("watchlist.matchBy")
                    if matchBy != .accessPoint {
                        TextField("Network name (SSID)", text: $ssid)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("watchlist.ssid")
                    }
                    if matchBy != .name {
                        TextField("MAC address (BSSID)", text: $bssid, prompt: Text("02:00:5E:00:53:01"))
                            .font(Theme.Fonts.mono)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .accessibilityIdentifier("watchlist.bssid")
                    }
                } header: {
                    Text("Match by")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(Theme.Colors.red)
                    } else {
                        Text(hint)
                    }
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle(isAdding ? "Add to watchlist" : "Edit network")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isAdding ? "Add" : "Save") { Task { await save() } }
                    .disabled(!canSave || saving)
                    .accessibilityIdentifier("watchlist.save")
            }
        }
        .onChange(of: matchBy) { problem = nil }
    }

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    private var ssidValue: String? { matchBy == .accessPoint ? nil : WatchlistMatcher.normalizeSSID(ssid) }
    private var bssidText: String? { matchBy == .name ? nil : WatchlistMatcher.normalizeSSID(bssid) }

    private var defaultLabel: String {
        WatchlistMatcher.resolveLabel(nil, ssid: ssidValue, bssid: bssidText.flatMap(WatchlistMatcher.parseBSSID) ?? bssidText)
    }

    private var canSave: Bool {
        switch matchBy {
        case .name: ssidValue != nil
        case .accessPoint: bssidText != nil
        case .both: ssidValue != nil && bssidText != nil
        }
    }

    private var hint: String {
        switch matchBy {
        case .name: "Alerts for this network name on any access point. Case does not matter."
        case .accessPoint: "Alerts for this one access point, whatever name it broadcasts."
        case .both: "Alerts only when this access point broadcasts this network name."
        }
    }

    private func save() async {
        var bssidValue: String?
        if let bssidText {
            guard let parsed = WatchlistMatcher.parseBSSID(bssidText) else {
                problem = "Enter a MAC address such as 02:00:5E:00:53:01."
                return
            }
            bssidValue = parsed
        }
        if let ssidValue, ssidValue.count > WatchlistLimits.maxSSIDLength {
            problem = "A network name has at most \(WatchlistLimits.maxSSIDLength) characters."
            return
        }
        saving = true
        defer { saving = false }
        switch mode {
        case .add(_, _, let turnOnAlerts):
            switch await app.watchlist.add(label: label, ssid: ssidValue, bssid: bssidValue, turnOnAlerts: turnOnAlerts) {
            case .added:
                dismiss()
            case .duplicate: problem = "You already watch this network."
            case .invalid: problem = "Enter a network name or a MAC address."
            }
        case .edit(let entry):
            switch await app.watchlist.update(entry, label: label, ssid: ssidValue, bssid: bssidValue) {
            case .saved: dismiss()
            case .duplicate: problem = "You already watch this network."
            case .invalid: problem = "Enter a network name or a MAC address."
            }
        }
    }
}
