import SurveyCore
import SwiftUI

/// Name, radius and delete for one privacy zone. A new zone is saved only
/// when the user taps Add; changes to an existing zone save however the
/// sheet closes.
struct PrivacyZoneEditor: View {
    static let defaultRadius: Double = 100
    static let radiusRange: ClosedRange<Double> = 25...2000
    static let footer = "When the phone has a location fix, records and track points inside this circle are dropped before they are stored, so they never reach this phone's files or any export."

    @State var zone: PrivacyZone
    var isNew = false
    let units: DisplayUnits
    let onSave: (PrivacyZone) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var finished = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("Name", text: $zone.name)
                            .accessibilityIdentifier("zone.name")
                    }
                    Section {
                        LabeledContent("Radius", value: DataFormat.distance(zone.radiusMeters, units: units))
                        Slider(value: logRadius, in: log(Self.radiusRange.lowerBound)...log(Self.radiusRange.upperBound)) {
                            Text("Radius")
                        } minimumValueLabel: {
                            Text(DataFormat.distance(Self.radiusRange.lowerBound, units: units)).font(Theme.Fonts.caption)
                        } maximumValueLabel: {
                            Text(DataFormat.distance(Self.radiusRange.upperBound, units: units)).font(Theme.Fonts.caption)
                        }
                        .accessibilityValue(DataFormat.distance(zone.radiusMeters, units: units))
                        .accessibilityIdentifier("zone.radius")
                    } footer: {
                        Text(Self.footer)
                    }
                    if !isNew {
                        Section {
                            Button("Delete zone", role: .destructive) { confirmingDelete = true }
                                .accessibilityIdentifier("zone.delete")
                                .confirmationDialog("Delete this privacy zone?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                                    Button("Delete zone", role: .destructive) {
                                        finished = true
                                        onDelete()
                                        dismiss()
                                    }
                                } message: {
                                    Text("Records inside it will be stored again from now on.")
                                }
                        }
                    }
                }
                .panelRows()
            }
            .themedList()
            .onDisappear {
                // An existing zone keeps its changes however the sheet closes.
                if !isNew && !finished { onSave(zone) }
            }
            .navigationTitle(isNew ? "New privacy zone" : "Privacy zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isNew {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            finished = true
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
                            finished = true
                            onSave(zone)
                            dismiss()
                        }
                        .accessibilityIdentifier("zone.add")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .interactiveDismissDisabled(isNew)
    }

    /// The slider moves on a log scale so small radii are easy to set.
    private var logRadius: Binding<Double> {
        Binding(
            get: { log(zone.radiusMeters) },
            set: { zone.radiusMeters = (exp($0) / 5).rounded() * 5 }
        )
    }
}

/// A zone in the editor; new zones are not saved until the user adds them.
struct ZoneEdit: Identifiable {
    var zone: PrivacyZone
    var isNew: Bool
    var id: UUID { zone.id }
}

/// A zone's center while editing zones: tap to change or delete it.
struct ZoneHandle: View {
    let zone: PrivacyZone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "hand.raised.fill")
                .font(.footnote)
                .foregroundStyle(Theme.Colors.onAccent)
                .frame(width: 32, height: 32)
                .background(Theme.Colors.red, in: Circle())
                .overlay(Circle().stroke(Theme.Colors.panel, lineWidth: 2))
                .shadow(color: Theme.Colors.shadow, radius: 2, y: 1)
                .frame(width: Theme.Spacing.touchTarget, height: Theme.Spacing.touchTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Edit privacy zone \(zone.name)")
    }
}
