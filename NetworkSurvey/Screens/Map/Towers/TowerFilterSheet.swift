import SurveyCore
import SwiftUI
import Towers

/// Which towers the map shows. Changes apply as they are made.
struct TowerFilterSheet: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(TowerLayerModel.self) private var towers
    @Environment(\.dismiss) private var dismiss

    /// Newest first, as most people look for 5G and LTE.
    static let technologies: [(TowerRadio, String)] = [
        (.nr, "5G NR"), (.lte, "4G LTE"), (.umts, "3G UMTS"), (.gsm, "2G GSM"), (.cdma, "2G CDMA"),
    ]
    static let ages: [(TowerAge, String)] = [
        (.any, "Any time"), (.sixMonths, "Last 6 months"), (.oneYear, "Last year"),
        (.twoYears, "Last 2 years"), (.fiveYears, "Last 5 years"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Self.technologies, id: \.0) { radio, title in
                        Toggle(title, isOn: technologyBinding(radio))
                            .accessibilityIdentifier("towers.filter.\(radio.rawValue)")
                    }
                } header: {
                    Text("Technology")
                } footer: {
                    if settings[Settings.towerTechnologies].isEmpty {
                        Text("Turn on at least one technology to see towers.")
                    }
                }

                Section {
                    NavigationLink {
                        TowerOperatorPicker()
                    } label: {
                        LabeledContent("Operator", value: operatorTitle)
                    }
                    .accessibilityIdentifier("towers.filter.operator")
                }

                Section {
                    Picker("Source", selection: settings.binding(Settings.towerSource)) {
                        Text("OpenCelliD").tag(TowerSource.openCelliD)
                        Text("BTSearch (Poland only)").tag(TowerSource.btSearch)
                    }
                    Picker("Last seen", selection: ageBinding) {
                        ForEach(Self.ages, id: \.0) { Text($1).tag($0) }
                    }
                    .disabled(!settings.towerFilters.ageApplies)
                } header: {
                    Text("Data")
                } footer: {
                    Text(settings.towerFilters.ageApplies
                        ? "Locations are estimates from crowd-sourced measurements and can be off by hundreds of meters."
                        : "BTSearch has no last seen dates, so every tower shows.")
                }
            }
            .navigationTitle("Tower filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var operatorTitle: String {
        guard let plmn = settings.towerFilters.plmn else { return "All" }
        return towers.name(of: plmn) ?? plmn.description
    }

    private var ageBinding: Binding<TowerAge> {
        Binding(
            get: { TowerAge(months: settings[Settings.towerMaxAgeMonths]) },
            set: { settings[Settings.towerMaxAgeMonths] = $0.months ?? 0 }
        )
    }

    private func technologyBinding(_ radio: TowerRadio) -> Binding<Bool> {
        Binding(
            get: { settings[Settings.towerTechnologies].contains(radio) },
            set: { on in
                var set = settings[Settings.towerTechnologies]
                if on { set.insert(radio) } else { set.remove(radio) }
                settings[Settings.towerTechnologies] = set
            }
        )
    }
}

/// All operators, one seen on the map, or one entered by code.
private struct TowerOperatorPicker: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(TowerLayerModel.self) private var towers
    @Environment(\.dismiss) private var dismiss
    @State private var mcc = ""
    @State private var mnc = ""

    var body: some View {
        let selected = settings.towerFilters.plmn
        Form {
            Section {
                row(nil, title: "All operators", selected: selected == nil)
                ForEach(seen, id: \.self) { plmn in
                    row(plmn, title: towers.name(of: plmn) ?? plmn.description, selected: plmn == selected)
                }
            } footer: {
                Text("Operators appear here as the map loads their towers.")
            }
            Section {
                TextField("MCC", text: $mcc)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("towers.operator.mcc")
                TextField("MNC", text: $mnc)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("towers.operator.mnc")
                Button("Show only this operator") { choose(entered) }
                    .disabled(entered == nil)
            } header: {
                Text("By code")
            } footer: {
                Text("MCC is 3 digits, MNC is 2 or 3. For example 310 and 410.")
            }
        }
        .navigationTitle("Operator")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            mcc = selected?.mcc ?? ""
            mnc = selected?.mnc ?? ""
        }
    }

    /// Seen operators plus the chosen one, by name.
    private var seen: [Plmn] {
        var plmns = towers.operatorsSeen
        if let selected = settings.towerFilters.plmn { plmns.insert(selected) }
        return plmns.sorted { (towers.name(of: $0) ?? "~\($0)", $0) < (towers.name(of: $1) ?? "~\($1)", $1) }
    }

    private var entered: Plmn? { Plmn(string: "\(mcc)-\(mnc)") }

    private func row(_ plmn: Plmn?, title: String, selected: Bool) -> some View {
        Button { choose(plmn) } label: {
            HStack(spacing: Theme.Spacing.m) {
                if let plmn {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(TowerMarkerView.color(plmn))
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).foregroundStyle(Theme.Colors.ink)
                    if let plmn, towers.name(of: plmn) != nil {
                        Text(plmn.description)
                            .font(Theme.Fonts.caption.monospacedDigit())
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.Colors.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func choose(_ plmn: Plmn?) {
        settings[Settings.towerOperator] = plmn?.description ?? ""
        dismiss()
    }
}
