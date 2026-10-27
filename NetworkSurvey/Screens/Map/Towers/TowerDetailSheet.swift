import CoreLocation
import MapKit
import SurveyCore
import SwiftUI
import Towers

/// The towers a tap picked: one, or every tower at one site.
struct TowerSelection: Identifiable, Equatable {
    var towers: [Tower]
    var id: String { towers.map(\.id).joined(separator: ",") }
}

/// A tower's details, or a list first when several share a site.
struct TowerDetailSheet: View {
    let selection: TowerSelection
    @Environment(TowerLayerModel.self) private var model

    var body: some View {
        NavigationStack {
            if selection.towers.count == 1 {
                TowerDetailView(tower: selection.towers[0])
            } else {
                List(sorted) { tower in
                    NavigationLink { TowerDetailView(tower: tower) } label: { row(tower) }
                }
                .navigationTitle("\(selection.towers.count) towers here")
                .navigationBarTitleDisplayMode(.inline)
                .accessibilityIdentifier("tower.list")
            }
        }
    }

    private var sorted: [Tower] {
        selection.towers.sorted { ($0.plmn, $1.technology ?? .gsm, $0.cid) < ($1.plmn, $0.technology ?? .gsm, $1.cid) }
    }

    private func row(_ tower: Tower) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            TowerBadge(tower: tower)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(model.name(of: tower.plmn) ?? tower.plmn.description)
                    .font(Theme.Fonts.rowTitle)
                Text(TowerDetailView.identity(tower))
                    .font(Theme.Fonts.caption.monospacedDigit())
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
    }
}

/// The operator-colored glyph with the generation.
struct TowerBadge: View {
    let tower: Tower

    var body: some View {
        Text(tower.technology?.generation ?? tower.radio)
            .font(Theme.Fonts.tag.monospacedDigit())
            .foregroundStyle(Theme.Colors.onAccent)
            .frame(width: 32, height: 32)
            .background(TowerMarkerView.color(tower.plmn), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct TowerDetailView: View {
    let tower: Tower
    @Environment(TowerLayerModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @State private var scene: MKLookAroundScene?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                HStack(spacing: Theme.Spacing.m) {
                    TowerBadge(tower: tower)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(model.name(of: tower.plmn) ?? "Operator \(tower.plmn.description)")
                            .font(Theme.Fonts.sectionTitle)
                        Text("\(Self.technologyName(tower)) · \(tower.plmn.description)")
                            .font(Theme.Fonts.body.monospacedDigit())
                            .foregroundStyle(Theme.Colors.ink2)
                    }
                }
                .accessibilityElement(children: .combine)
                if let scene {
                    LookAroundPreview(initialScene: scene)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile))
                        .listRowInsets(EdgeInsets())
                        .accessibilityLabel("Look Around near this tower")
                }
            }

            Section("Cell") {
                field(tower.technology?.areaName ?? "Area", "\(tower.area)")
                field("Cell ID", "\(tower.cid)")
                if let eNodeB = tower.eNodeB {
                    field("eNodeB", "\(eNodeB.id)")
                    field("Sector", "\(eNodeB.sector)")
                }
                if tower.unit > 0 { field(tower.technology == .umts ? "PSC" : "PCI", "\(tower.unit)") }
            }

            Section {
                if let distance { field("From you", DataFormat.distance(distance, units: settings[Settings.units])) }
                if tower.range > 0 { field("Range", DataFormat.distance(Double(tower.range), units: settings[Settings.units])) }
                field("Position", String(format: "%.5f, %.5f", tower.lat, tower.lon))
                if tower.samples > 0 { field("Measurements", DataFormat.count(tower.samples)) }
                if let created = tower.createdDate { field("First seen", DataFormat.dateTime(created)) }
                if let updated = tower.updatedDate { field("Last updated", DataFormat.dateTime(updated)) }
                field("Source", tower.source)
                if let comments = tower.comments, !comments.isEmpty { field("Comments", comments) }
            } header: {
                Text("Location")
            } footer: {
                Text("Positions are estimated from crowd-sourced measurements and can be off by hundreds of meters.")
            }

            Section {
                Button { openInMaps() } label: { Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") }
                Button {
                    UIPasteboard.general.string = tower.towerID
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy cell identity", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        }
        .navigationTitle("Tower")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("tower.detail")
        .task(id: tower.id) {
            let request = MKLookAroundSceneRequest(coordinate: tower.coordinate)
            scene = try? await request.scene
        }
    }

    private var distance: Double? {
        CLLocationManager().location.map { $0.distance(from: CLLocation(latitude: tower.lat, longitude: tower.lon)) }
    }

    private var shareText: String {
        let name = model.name(of: tower.plmn).map { "\($0) " } ?? ""
        return "\(name)\(Self.technologyName(tower)) tower \(tower.towerID) at "
            + "https://maps.apple.com/?ll=\(tower.lat),\(tower.lon)&q=Tower"
    }

    private func field(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(Theme.Fonts.body.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func openInMaps() {
        let item: MKMapItem
        if #available(iOS 26, *) {
            item = MKMapItem(location: CLLocation(latitude: tower.lat, longitude: tower.lon), address: nil)
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: tower.coordinate))
        }
        item.name = TowerMarkerView.title(tower, names: model.operatorNames)
        item.openInMaps()
    }

    /// "4G LTE", or the raw radio name.
    static func technologyName(_ tower: Tower) -> String {
        guard let technology = tower.technology else { return tower.radio }
        return "\(technology.generation) \(technology.rawValue)"
    }

    /// "4G · TAC 1234 · CID 26881281".
    static func identity(_ tower: Tower) -> String {
        "\(tower.technology?.generation ?? tower.radio) · \(tower.technology?.areaName ?? "Area") \(tower.area) · CID \(tower.cid)"
    }
}

extension Tower {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}
