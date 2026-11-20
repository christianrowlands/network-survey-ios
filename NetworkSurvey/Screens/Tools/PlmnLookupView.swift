import SwiftUI
import Towers

/// Finds mobile network operators by MCC, MCC-MNC, country or name in the
/// NS Tower Service's MCC-MNC list.
struct PlmnLookupView: View {
    /// What to search for when the screen opens, for example a tower's "310-260".
    let initialText: String
    @Environment(TowerLayerModel.self) private var towers
    @State private var text: String
    @State private var result: PlmnSearchResult?
    @State private var loading = false
    @State private var failure: TowerServiceError?
    @State private var attempt = 0
    @FocusState private var focused: Bool

    init(initialText: String = "") {
        self.initialText = initialText
        _text = State(initialValue: initialText)
    }

    /// Waits this long after the last keystroke before searching.
    static let debounce = Duration.milliseconds(350)

    private struct Request: Equatable {
        var query: PlmnSearchQuery?
        var typed: Bool
        var attempt: Int
    }

    var body: some View {
        let query = PlmnSearchQuery(text)
        List {
            Group {
                if towers.hasKey {
                    Section {
                        TextField("Search", text: $text, prompt: Text("Country, operator or MCC-MNC"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.search)
                            .focused($focused)
                            .accessibilityIdentifier("plmn.input")
                    } footer: {
                        Text("Search by MCC (310), MCC-MNC (310-260), country or operator name.")
                    }
                    results(for: query)
                } else {
                    message("No tower service key", "This build has no key for the NS Tower Service, so it can't look up operators.")
                        .accessibilityIdentifier("plmn.noKey")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("PLMN lookup")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focused = text.isEmpty && towers.hasKey }
        .task(id: Request(query: query, typed: text != initialText, attempt: attempt)) {
            await search(query, debounce: text != initialText)
        }
    }

    @ViewBuilder
    private func results(for query: PlmnSearchQuery?) -> some View {
        if query == nil {
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                Section { message("Keep typing", "Enter at least \(PlmnSearchQuery.minimumLength) characters.") }
            }
        } else if let failure, !loading {
            Section {
                message(Self.title(failure), Self.detail(failure))
                Button("Try Again") { attempt += 1 }
                    .accessibilityIdentifier("plmn.retry")
            }
        } else if let result {
            Section {
                if result.records.isEmpty {
                    message("No matches", "Try a country, an operator or an MCC such as 310.")
                }
                ForEach(result.records) { record in
                    NavigationLink { PlmnRecordDetailView(record: record) } label: { PlmnRecordRow(record: record) }
                }
            } header: {
                HStack(spacing: Theme.Spacing.s) {
                    Text(result.truncated
                        ? "First \(DataFormat.count(result.records.count, "operator"))"
                        : DataFormat.count(result.records.count, "operator"))
                    if loading { ProgressView().controlSize(.small) }
                }
            } footer: {
                if result.truncated {
                    Text("Showing the first \(TowerClient.plmnSearchLimit) matches. Add more to the search to narrow it.")
                }
            }
        } else if loading {
            Section {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func search(_ query: PlmnSearchQuery?, debounce: Bool) async {
        guard let query, towers.hasKey else {
            result = nil
            failure = nil
            loading = false
            return
        }
        loading = true
        if debounce {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
        }
        do {
            let found = try await towers.client.searchOperators(query)
            guard !Task.isCancelled else { return }
            result = found
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            result = nil
            failure = error
        }
        loading = false
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(Theme.Fonts.sectionTitle).foregroundStyle(Theme.Colors.ink)
            Text(detail).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.ink2)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    static func title(_ error: TowerServiceError) -> String {
        switch error {
        case .network: "No connection"
        case .missingKey: "No tower service key"
        default: "Lookup unavailable"
        }
    }

    static func detail(_ error: TowerServiceError) -> String {
        switch error {
        case .network: "Couldn't reach the NS Tower Service. Check your connection and try again."
        case .missingKey: "This build has no key for the NS Tower Service, so it can't look up operators."
        case .server(status: 429): "Too many lookups right now. Try again in a minute."
        default: "The NS Tower Service didn't answer as expected. Try again shortly."
        }
    }
}

/// An operator: name and code, then the company and country.
struct PlmnRecordRow: View {
    let record: PlmnRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                Text(record.name ?? "Unknown operator")
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(record.name == nil ? Theme.Colors.ink2 : Theme.Colors.ink)
                    .lineLimit(2)
                Spacer(minLength: Theme.Spacing.s)
                Text(record.plmn.description)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink)
            }
            if let operatorName = record.operatorName {
                Text(operatorName)
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                    .lineLimit(2)
            }
            if let place = Self.place(record) {
                Text(place)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            if let status = record.status, !record.isOperational {
                TagPill(text: status, color: Theme.Colors.amberText)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }

    /// "🇺🇸 United States of America", or the ISO codes when there is no country.
    static func place(_ record: PlmnRecord) -> String? {
        guard let name = record.country ?? record.iso, !name.isEmpty else { return nil }
        return [record.flag, name].compactMap { $0 }.joined(separator: " ")
    }
}

/// Everything the list has on one operator.
struct PlmnRecordDetailView: View {
    let record: PlmnRecord

    var body: some View {
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(record.name ?? "Unknown operator")
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                        if let operatorName = record.operatorName {
                            Text(operatorName).font(Theme.Fonts.body).foregroundStyle(Theme.Colors.ink2)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityElement(children: .combine)
                }
                Section("Network") {
                    DetailRow(label: "PLMN", value: record.plmn.description, mono: true)
                    DetailRow(label: "MCC", value: record.mcc, mono: true)
                    DetailRow(label: "MNC", value: record.mnc, mono: true)
                    if let tadig = record.tadig, !tadig.isEmpty { DetailRow(label: "TADIG", value: tadig, mono: true) }
                    if let status = record.status, !status.isEmpty { DetailRow(label: "Status", value: status) }
                }
                Section("Location") {
                    if let place = PlmnRecordRow.place(record) { DetailRow(label: "Country", value: place) }
                    if let iso = record.iso, !iso.isEmpty { DetailRow(label: "ISO code", value: iso) }
                    if let region = record.region, !region.isEmpty { DetailRow(label: "Region", value: region) }
                }
                if let bands = record.bands, !bands.isEmpty {
                    Section("Bands") {
                        Text(bands.replacingOccurrences(of: " / ", with: ", "))
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                    }
                }
                Section {
                } footer: {
                    Text("From the NS Tower Service's MCC-MNC list, built from Wikipedia's mobile network code tables (CC BY-SA 4.0) and the US and Canadian MNC registries.")
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle(record.plmn.description)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("plmn.detail")
    }
}
