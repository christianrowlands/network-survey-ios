import SurveyCore
import SwiftUI

struct PrivacyZonesView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(MapCommands.self) private var mapCommands
    @Environment(AppModel.self) private var app
    @State private var editedZone: PrivacyZone?

    var body: some View {
        let zones = settings[Settings.privacyZones]
        List {
            Group {
                Section {
                    ForEach(zones) { zone in
                        Button {
                            editedZone = zone
                        } label: {
                            LabeledContent {
                                Text(DataFormat.distance(zone.radiusMeters, units: settings[Settings.units]))
                            } label: {
                                Text(zone.name.isEmpty ? "Privacy zone" : zone.name)
                                    .foregroundStyle(Theme.Colors.ink)
                                Text(String(format: "%.5f, %.5f", zone.center.latitude, zone.center.longitude))
                                    .font(Theme.Fonts.mono)
                            }
                        }
                    }
                    .onDelete { offsets in
                        var list = zones
                        list.remove(atOffsets: offsets)
                        settings[Settings.privacyZones] = list
                    }
                } footer: {
                    Text("When the phone has a location fix, records and track points inside a zone are dropped before they are stored. Add a zone from the Map: touch and hold where the zone goes.")
                }
            }
            .panelRows()
        }
        .themedList()
        .overlay {
            if zones.isEmpty {
                ContentUnavailableView {
                    Label("No privacy zones", systemImage: "hand.raised")
                } description: {
                    Text("Add zones on the Map around places such as your home, so nothing is recorded there.")
                } actions: {
                    Button("Add a zone on the Map") { addOnMap() }
                }
            }
        }
        .navigationTitle("Privacy zones")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !zones.isEmpty { EditButton() }
                Button {
                    addOnMap()
                } label: {
                    Label("Add zone", systemImage: "plus")
                }
                .accessibilityIdentifier("zones.add")
            }
        }
        .sheet(item: $editedZone) { zone in
            PrivacyZoneEditor(zone: zone, units: settings[Settings.units]) { updated in
                var list = settings[Settings.privacyZones]
                if let index = list.firstIndex(where: { $0.id == updated.id }) { list[index] = updated }
                settings[Settings.privacyZones] = list
            } onDelete: {
                settings[Settings.privacyZones] = settings[Settings.privacyZones].filter { $0.id != zone.id }
            }
        }
    }

    /// Opens the Map in zone editing, where a long press adds a zone.
    private func addOnMap() {
        mapCommands.editZones = true
        app.selectedTab = .map
    }
}

struct IgnoreListView: View {
    @Environment(SettingsModel.self) private var settings
    @State private var adding = false

    var body: some View {
        let entries = settings[Settings.ignoreList]
        List {
            Group {
                ForEach(IgnoreEntry.Kind.allCases, id: \.self) { kind in
                    let matching = entries.filter { $0.kind == kind }
                    if !matching.isEmpty {
                        Section(Self.title(kind)) {
                            ForEach(matching) { entry in
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(entry.value)
                                        .font(kind == .ssid ? Theme.Fonts.rowTitle : Theme.Fonts.mono)
                                        .foregroundStyle(Theme.Colors.ink)
                                    if !entry.note.isEmpty {
                                        Text(entry.note).font(Theme.Fonts.caption).foregroundStyle(Theme.Colors.ink2)
                                    }
                                }
                            }
                            .onDelete { offsets in
                                let removed = Set(offsets.map { matching[$0].id })
                                settings[Settings.ignoreList] = entries.filter { !removed.contains($0.id) }
                            }
                        }
                    }
                }
                if !entries.isEmpty {
                    Section {
                        EmptyView()
                    } footer: {
                        Text(Self.footer)
                    }
                }
            }
            .panelRows()
        }
        .themedList()
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("Nothing ignored", systemImage: "eye.slash")
                } description: {
                    Text("Add networks or devices you never want recorded, such as your own. Use Ignore on a detail screen, or add one here.")
                } actions: {
                    Button("Add entry") { adding = true }
                }
            }
        }
        .navigationTitle("Ignore list")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityIdentifier("ignore.add")
            }
        }
        .sheet(isPresented: $adding) {
            AddIgnoreEntryView()
        }
    }

    static let footer = "Matching records are dropped before they are stored. Network names match exactly, including case. Addresses match with or without separators, in any case."

    static func title(_ kind: IgnoreEntry.Kind) -> String {
        switch kind {
        case .ssid: "Network names (SSID)"
        case .bssid: "Access points (BSSID)"
        case .mac: "Devices (MAC address)"
        case .macPrefix: "Address prefixes"
        }
    }
}

private struct AddIgnoreEntryView: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var kind = IgnoreEntry.Kind.ssid
    @State private var value = ""
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Picker("Type", selection: $kind) {
                        Text("Network name").tag(IgnoreEntry.Kind.ssid)
                        Text("Access point").tag(IgnoreEntry.Kind.bssid)
                        Text("Device").tag(IgnoreEntry.Kind.mac)
                        Text("Address prefix").tag(IgnoreEntry.Kind.macPrefix)
                    }
                    Section {
                        TextField(placeholder, text: $value)
                            .font(kind == .ssid ? Theme.Fonts.rowTitle : Theme.Fonts.mono)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ignore.value")
                        TextField("Note (optional)", text: $note)
                    } footer: {
                        if let problem { Text(problem).foregroundStyle(Theme.Colors.red) } else { Text(hint) }
                    }
                }
                .panelRows()
            }
            .themedList()
            .navigationTitle("Add to ignore list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        var list = settings[Settings.ignoreList]
                        list.append(IgnoreEntry(kind: kind, value: trimmed, note: note))
                        settings[Settings.ignoreList] = list
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty || problem != nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// SSIDs keep their spaces; addresses do not.
    private var trimmed: String {
        kind == .ssid ? value : value.trimmingCharacters(in: .whitespaces)
    }

    private var placeholder: String {
        switch kind {
        case .ssid: "Network name"
        case .bssid, .mac: "02:00:5E:00:53:01"
        case .macPrefix: "02:00:5E"
        }
    }

    private var hint: String {
        switch kind {
        case .ssid: "Matches the exact name, including case."
        case .bssid: "Drops the access point and clients connected to it."
        case .mac: "Drops any access point, client or Bluetooth device with this address."
        case .macPrefix: "Drops every address that starts with these digits, for example a manufacturer prefix."
        }
    }

    private var problem: String? {
        guard kind != .ssid, !trimmed.isEmpty else { return nil }
        guard let digits = MACAddress.normalizedHex(trimmed) else { return "Use hex digits, optionally separated by colons or dashes." }
        if kind != .macPrefix && digits.count != 12 { return "A full address has 12 hex digits." }
        if kind == .macPrefix && digits.count > 12 { return "A prefix has at most 12 hex digits." }
        return nil
    }
}
