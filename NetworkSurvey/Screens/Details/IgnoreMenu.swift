import SurveyCore
import SwiftUI

/// A candidate ignore list entry offered on a detail screen.
struct IgnoreChoice: Identifiable {
    var kind: IgnoreEntry.Kind
    var value: String
    var title: String
    var id: String { "\(kind.rawValue)-\(value)" }
}

/// Toolbar menu that adds this item to the ignore list.
struct IgnoreMenu: View {
    let choices: [IgnoreChoice]

    @Environment(SettingsModel.self) private var settings
    @State private var added: IgnoreChoice?

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                if isIgnored(choice) {
                    Label("\(choice.title) (already ignored)", systemImage: "checkmark")
                } else {
                    Button(choice.title) { add(choice) }
                }
            }
        } label: {
            Text("Ignore")
        }
        .accessibilityIdentifier("detail.ignore")
        .alert("Added to the ignore list", isPresented: Binding(get: { added != nil }, set: { if !$0 { added = nil } })) {
            Button("OK") {}
        } message: {
            Text("New records that match \(added?.value ?? "") are dropped before they are stored. Data already collected stays. Manage the list in Settings.")
        }
    }

    private func isIgnored(_ choice: IgnoreChoice) -> Bool {
        settings[Settings.ignoreList].contains { $0.kind == choice.kind && $0.value == choice.value }
    }

    private func add(_ choice: IgnoreChoice) {
        var list = settings[Settings.ignoreList]
        list.append(IgnoreEntry(kind: choice.kind, value: choice.value))
        settings[Settings.ignoreList] = list
        added = choice
    }
}
