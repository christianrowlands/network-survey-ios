import SwiftUI

// Live Activity views, compiled into the widget extension (which shows them)
// and the app (which shows a preview of them for design review).

/// The Lock Screen presentation.
struct SurveyActivityLockScreen: View {
    let attributes: SurveyActivityAttributes
    let state: SurveyActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                SurveyActivityBadge(state: state)
                Spacer()
                SurveyActivityElapsed(attributes: attributes, state: state)
                    .font(Theme.Fonts.sectionTitle.monospacedDigit())
                    .foregroundStyle(Theme.Colors.ink)
            }
            SurveyActivityCounts(state: state)
            SurveyActivityBoards(state: state)
        }
        .padding(Theme.Spacing.l)
    }
}

/// "Recording", "Stopped" or "Check the Scout", with a dot.
struct SurveyActivityBadge: View {
    let state: SurveyActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text)
                .font(Theme.Fonts.label)
                .foregroundStyle(color)
        }
    }

    private var text: String {
        if state.stoppedAt != nil { return "Survey stopped" }
        return state.problem ?? "Recording"
    }

    private var color: Color {
        if state.stoppedAt != nil { return Theme.Colors.ink2 }
        return state.problem != nil ? Theme.Colors.amber : Theme.Colors.red
    }
}

/// Counts up from the start; frozen at the stop time once stopped.
struct SurveyActivityElapsed: View {
    let attributes: SurveyActivityAttributes
    let state: SurveyActivityAttributes.ContentState

    var body: some View {
        if let stopped = state.stoppedAt {
            Text(ElapsedFormat.string(stopped.timeIntervalSince(attributes.startedAt)))
                .monospacedDigit()
        } else {
            Text(timerInterval: attributes.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

struct SurveyActivityCounts: View {
    let state: SurveyActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: Theme.Spacing.l) {
            count(state.accessPoints, "APs", color: Theme.Colors.wifi)
            count(state.clients, "Clients", color: Theme.Colors.wifiClient)
            count(state.bluetoothDevices, "BLE", color: Theme.Colors.bluetooth)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 0) {
                Text(state.recordCount.formatted())
                    .font(Theme.Fonts.counter.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Colors.ink)
                Text("records")
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
    }

    private func count(_ value: Int, _ label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted())
                .font(Theme.Fonts.counter.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.ink)
            HStack(spacing: Theme.Spacing.xxs) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SurveyActivityBoards: View {
    let state: SurveyActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Label(boardsText, systemImage: "sensor.fill")
                .foregroundStyle(state.boardsConnected < state.boardsInSurvey ? Theme.Colors.amberText : Theme.Colors.ink2)
            if let battery = state.lowestBatteryPercent {
                Label(state.boardsConnected > 1 ? "Lowest \(battery)%" : "\(battery)%",
                      systemImage: battery < 20 ? "battery.25percent" : "battery.75percent")
                    .foregroundStyle(battery < 15 ? Theme.Colors.red : Theme.Colors.ink2)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.Fonts.caption)
    }

    private var boardsText: String {
        if state.boardsInSurvey > state.boardsConnected {
            return "\(state.boardsConnected) of \(state.boardsInSurvey) Scouts connected"
        }
        return state.boardsConnected == 1 ? "1 Scout connected" : "\(state.boardsConnected) Scouts connected"
    }
}
