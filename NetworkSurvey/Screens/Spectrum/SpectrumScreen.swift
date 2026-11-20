import BoardProtocol
import SurveyCore
import SwiftUI

/// Opens the Wi-Fi spectrum from the access point list.
struct SpectrumRoute: Hashable {}

/// How busy each Wi-Fi channel is: the access points heard in the last two
/// minutes of the shown survey, one chart per band, kept live while the
/// survey records.
struct SpectrumScreen: View {
    @Environment(SurveyData.self) private var data
    @Environment(ListsNavigation.self) private var navigation
    @State private var sectionID = WifiSpectrum.sections[0].id
    @State private var aps: [AccessPointRow] = []
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        Group {
            if let sessionID = data.sessionID {
                content(sessionID: sessionID)
                    .task(id: sessionID) { await observe(sessionID) }
            } else {
                NoSurveyView(message: "Start a survey to see how busy each Wi-Fi channel is.")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                PastSurveyBar()
                if data.sessionID != nil { pickers }
            }
            .background(Theme.Colors.ground)
        }
        .screenBackground()
        .navigationTitle("Wi-Fi spectrum")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var section: WifiSpectrum.Section {
        WifiSpectrum.sections.first { $0.id == sectionID } ?? WifiSpectrum.sections[0]
    }

    private var pickers: some View {
        let counts = WifiSpectrum.counts(aps)
        let bandSections = WifiSpectrum.sections(of: section.band)
        return VStack(spacing: Theme.Spacing.s) {
            Picker("Band", selection: bandBinding(counts: counts)) {
                ForEach(SpectrumPresentation.bands(counts: counts), id: \.self) { band in
                    Text(SpectrumPresentation.bandName(band)).tag(band)
                }
            }
            .accessibilityIdentifier("spectrum.band")
            if bandSections.count > 1 {
                Picker("Channels", selection: $sectionID) {
                    ForEach(bandSections) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("spectrum.channels")
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, Theme.Spacing.screenGutter)
        .padding(.vertical, Theme.Spacing.s)
    }

    /// Picking a band shows its first channel range with access points in it.
    private func bandBinding(counts: [WifiSpectrum.Section.ID: Int]) -> Binding<NSBBand> {
        Binding(
            get: { section.band },
            set: { band in
                guard band != section.band else { return }
                let sections = WifiSpectrum.sections(of: band)
                sectionID = (sections.first { counts[$0.id, default: 0] > 0 } ?? sections[0]).id
            }
        )
    }

    @ViewBuilder
    private func content(sessionID: String) -> some View {
        if let failure {
            ContentUnavailableView("Could not read the survey", systemImage: "exclamationmark.triangle",
                                   description: Text(failure))
        } else if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if aps.isEmpty {
            ContentUnavailableView {
                Label("No access points", systemImage: "wifi")
            } description: {
                Text("Access points appear here as the survey hears their beacons.")
            }
        } else {
            let placements = WifiSpectrum.placements(aps, in: section, slots: Theme.Colors.spectrum.count)
            List {
                Section {
                    SpectrumChart(section: section, placements: placements) { placement in
                        navigation.path.append(DetailRoute.accessPoint(sessionID: sessionID, bssid: placement.bssid))
                    }
                    .padding(.vertical, Theme.Spacing.s)
                } header: {
                    header(placements: placements)
                }
                .panelRows()
                if !placements.isEmpty {
                    Section("Access points") {
                        ForEach(placements) { placement in
                            NavigationLink(value: DetailRoute.accessPoint(sessionID: sessionID, bssid: placement.bssid)) {
                                SpectrumLegendRow(placement: placement)
                            }
                        }
                    }
                    .panelRows()
                }
            }
            .listStyle(.insetGrouped)
            .themedList()
            .accessibilityIdentifier("spectrum.list")
        }
    }

    private func header(placements: [WifiSpectrum.Placement]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(SpectrumPresentation.title(section))
                .font(Theme.Fonts.sectionTitle)
                .foregroundStyle(Theme.Colors.ink)
                .accessibilityAddTraits(.isHeader)
            Text(SpectrumPresentation.window(isPast: data.isShowingPast))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.ink2)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    private func observe(_ sessionID: String) async {
        aps = []
        loaded = false
        failure = nil
        let store = data.store
        do {
            for try await value in store.observe({ try StoreQueries.recentAccessPoints($0, sessionID: sessionID) }) {
                aps = value
                loaded = true
            }
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// An access point under the chart, with its curve's color.
private struct SpectrumLegendRow: View {
    let placement: WifiSpectrum.Placement

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Theme.Colors.spectrum(placement.colorSlot))
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(SpectrumPresentation.name(placement))
                    .font(Theme.Fonts.rowTitle.weight(.medium))
                    .foregroundStyle(placement.ssid == nil ? Theme.Colors.ink2 : Theme.Colors.ink)
                    .lineLimit(1)
                Text(SpectrumPresentation.channel(placement))
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.Colors.ink2)
                Text(placement.bssid)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            Spacer(minLength: Theme.Spacing.s)
            Text(DataFormat.dBm(placement.rssi))
                .font(Theme.Fonts.counter)
                .foregroundStyle(Theme.Colors.signal(Int32(clamping: placement.rssi)))
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}
