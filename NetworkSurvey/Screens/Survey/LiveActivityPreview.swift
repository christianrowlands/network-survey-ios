import SwiftUI

/// The Live Activity's Lock Screen and Dynamic Island layouts with sample
/// numbers, for design review (screenshots cannot show the real ones). Opened
/// with the launch argument `-NSOpenScreen liveActivity`.
struct LiveActivityPreview: View {
    private let attributes = SurveyActivityAttributes(
        missionID: "NS 00000000 20261022-140300",
        startedAt: Date().addingTimeInterval(-(42 * 60 + 17))
    )
    private let running = SurveyActivityAttributes.ContentState(
        recordCount: 18_234, accessPoints: 142, clients: 311, bluetoothDevices: 87,
        boardsConnected: 2, boardsInSurvey: 2, lowestBatteryPercent: 64
    )

    private var stopped: SurveyActivityAttributes.ContentState {
        var state = running
        state.stoppedAt = Date()
        return state
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                SectionHeader(title: "Lock Screen")
                card(running)
                card(SurveyActivityAttributes.ContentState(
                    recordCount: 9_120, accessPoints: 96, clients: 204, bluetoothDevices: 0,
                    boardsConnected: 1, boardsInSurvey: 2, lowestBatteryPercent: 12, boardProblem: true
                ))
                card(stopped)
                SectionHeader(title: "Dynamic Island, expanded")
                VStack(spacing: Theme.Spacing.s) {
                    HStack {
                        SurveyActivityBadge(state: running)
                        Spacer()
                        SurveyActivityElapsed(attributes: attributes, state: running)
                            .font(Theme.Fonts.counter.weight(.semibold))
                    }
                    SurveyActivityCounts(state: running)
                    SurveyActivityBoards(state: running)
                }
                .padding(Theme.Spacing.xl)
                .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
                .environment(\.colorScheme, .dark)
                SectionHeader(title: "Dynamic Island, compact")
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(Theme.Colors.wifi)
                    Spacer()
                    SurveyActivityElapsed(attributes: attributes, state: running)
                        .font(Theme.Fonts.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(maxWidth: 52)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .frame(width: 250, height: 37)
                .background(.black, in: Capsule())
                .environment(\.colorScheme, .dark)
                .frame(maxWidth: .infinity)
            }
            .padding(Theme.Spacing.screenGutter)
        }
        .screenBackground()
        .navigationTitle("Live Activity")
    }

    private func card(_ state: SurveyActivityAttributes.ContentState) -> some View {
        SurveyActivityLockScreen(attributes: attributes, state: state)
            .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
