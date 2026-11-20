import SurveyCore
import SwiftUI

/// Adds the networks of a shared link after the user confirms: what is new,
/// what is already saved, and "Add N". Opened by a watchlist link or by
/// pasting one.
struct WatchlistImportView: View {
    let set: WatchlistImportSet

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var failure: String?

    var body: some View {
        let plan = WatchlistImportPlanner.plan(existing: app.watchlist.entries, set: set)
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(title(plan))
                            .font(Theme.Fonts.screenTitle)
                            .foregroundStyle(Theme.Colors.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(summary(plan))
                            .font(Theme.Fonts.body)
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
                Section {
                    ForEach(plan.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                Text(row.label)
                                    .font(Theme.Fonts.rowTitle)
                                    .foregroundStyle(row.isDuplicate ? Theme.Colors.ink2 : Theme.Colors.ink)
                                WatchlistIdentity(entry: WatchlistEntry(label: row.label, ssid: row.ssid, bssid: row.bssid, createdAt: .now))
                            }
                            Spacer(minLength: Theme.Spacing.s)
                            if row.isDuplicate { TagPill(text: "Already saved", color: Theme.Colors.tagHidden) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } footer: {
                    if let failure {
                        Text(failure).foregroundStyle(Theme.Colors.red)
                    } else if plan.addedCount > 0 {
                        Text("Adding them turns watchlist alerts on. You can remove them anytime on the Watchlist screen.")
                    }
                }
            }
            .panelRows()
        }
        .themedList()
        .navigationTitle("Import networks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if plan.addedCount > 0 { Button("Cancel") { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                if plan.addedCount > 0 {
                    Button("Add \(plan.addedCount)") { Task { await add() } }
                        .disabled(importing)
                        .accessibilityIdentifier("watchlist.importConfirm")
                } else {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func title(_ plan: WatchlistImportPlan) -> String {
        if plan.addedCount == 0 { return "Already saved" }
        return set.name.map { "Add \u{201C}\($0)\u{201D}?" } ?? "Add networks to your watchlist?"
    }

    private func summary(_ plan: WatchlistImportPlan) -> String {
        if plan.addedCount == 0 {
            return plan.rows.count == 1
                ? "This network is already on your watchlist."
                : "All \(plan.rows.count) networks in this link are already on your watchlist."
        }
        let new = DataFormat.count(plan.addedCount, "new network")
        guard plan.duplicateCount > 0 else { return "From a link: \(new)." }
        return "From a link: \(new), \(DataFormat.count(plan.duplicateCount)) already saved."
    }

    private func add() async {
        importing = true
        defer { importing = false }
        do {
            try await app.store.importWatchlist(set)
            app.settings[Settings.watchlistEnabled] = true
            await app.watchlist.askForNotifications()
            dismiss()
        } catch {
            failure = "The networks could not be added: \(error.localizedDescription)"
        }
    }
}

/// Paste a watchlist link (or a message with one in it) to import it.
struct WatchlistPasteImport: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var problem: String?
    @State private var set: WatchlistImportSet?

    var body: some View {
        NavigationStack {
            if let set {
                WatchlistImportView(set: set)
            } else {
                Form {
                    Group {
                        Section {
                            TextField("Watchlist link", text: $text, prompt: Text("https://networksurvey.app/app/watchlist?d=..."), axis: .vertical)
                                .lineLimit(3...6)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .accessibilityIdentifier("watchlist.importText")
                            PasteButton(payloadType: String.self) { strings in
                                if let first = strings.first { text = first }
                            }
                        } footer: {
                            if let problem {
                                Text(problem).foregroundStyle(Theme.Colors.red)
                            } else {
                                Text("Paste a watchlist link someone shared with you. You see the networks before anything is added.")
                            }
                        }
                    }
                    .panelRows()
                }
                .themedList()
                .navigationTitle("Import from a link")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Next") { read() }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("watchlist.importNext")
                    }
                }
                .onChange(of: text) { problem = nil }
            }
        }
    }

    private func read() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = WatchlistLink.find(in: trimmed) ?? URL(string: trimmed).flatMap({ WatchlistLink.isWatchlistLink($0) ? $0 : nil })
        else {
            problem = "This is not a watchlist link. It starts with https://networksurvey.app/app/watchlist."
            return
        }
        do {
            set = try WatchlistLink.parse(url)
        } catch {
            problem = error.message
        }
    }
}

/// A link opened from outside the app: its networks to confirm, or why it
/// cannot be imported.
struct WatchlistLinkImport: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            switch Result(catching: { () throws(WatchlistLinkError) in try WatchlistLink.parse(url) }) {
            case .success(let set):
                WatchlistImportView(set: set)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Can't import this link", systemImage: "link.badge.plus")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
