import SurveyCore
import SwiftUI
import Towers

/// Finds a tower by its identity, in every technology.
struct TowerSearchSheet: View {
    /// Called with what was found; the map moves to it and shows it.
    let onFound: ([Tower]) -> Void
    @Environment(TowerLayerModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var mcc = ""
    @State private var mnc = ""
    @State private var area = ""
    @State private var cid = ""
    @State private var searching = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("MCC", $mcc, "towers.search.mcc")
                    field("MNC", $mnc, "towers.search.mnc")
                    field("LAC or TAC", $area, "towers.search.area")
                    field("Cell ID", $cid, "towers.search.cid")
                } footer: {
                    if let message {
                        Text(message).foregroundStyle(Theme.Colors.red)
                    } else {
                        Text("The cell ID is the full ID (for LTE, the ECI), not the PCI.")
                    }
                }
                Section {
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Text("Search")
                            if searching {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(query == nil || searching)
                    .accessibilityIdentifier("towers.search.go")
                }
            }
            .navigationTitle("Find a tower")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if mcc.isEmpty, let plmn = settings.towerFilters.plmn {
                    mcc = plmn.mcc
                    mnc = plmn.mnc
                }
            }
        }
    }

    private var query: (plmn: Plmn, area: Int, cid: Int64)? {
        guard let plmn = Plmn(string: "\(mcc)-\(mnc)"), let area = Int(area), let cid = Int64(cid) else { return nil }
        return (plmn, area, cid)
    }

    private func field(_ title: String, _ text: Binding<String>, _ id: String) -> some View {
        TextField(title, text: text)
            .keyboardType(.numberPad)
            .accessibilityIdentifier(id)
    }

    private func search() async {
        guard let query else { return }
        searching = true
        message = nil
        defer { searching = false }
        do {
            let found = try await model.client.search(mcc: query.plmn.mcc, mnc: query.plmn.mnc, area: query.area, cid: query.cid)
            if found.isEmpty {
                message = "No towers match this search."
            } else {
                onFound(found)
                dismiss()
            }
        } catch .missingKey {
            message = "This build has no tower service key."
        } catch {
            message = "Couldn't search for towers. Try again."
        }
    }
}
