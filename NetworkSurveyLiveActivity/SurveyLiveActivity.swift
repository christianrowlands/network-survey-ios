import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen and Dynamic Island views for a running survey: elapsed time,
/// unique counts, and the boards' connection and battery.
struct SurveyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SurveyActivityAttributes.self) { context in
            SurveyActivityLockScreen(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Theme.Colors.panel)
                .activitySystemActionForegroundColor(Theme.Colors.ink)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SurveyActivityBadge(state: context.state)
                        .padding(.leading, Theme.Spacing.xs)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SurveyActivityElapsed(attributes: context.attributes, state: context.state)
                        .font(Theme.Fonts.counter.weight(.semibold))
                        .frame(maxWidth: 88, alignment: .trailing)
                        .padding(.trailing, Theme.Spacing.xs)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: Theme.Spacing.s) {
                        SurveyActivityCounts(state: context.state)
                        SurveyActivityBoards(state: context.state)
                    }
                    .padding(.horizontal, Theme.Spacing.xs)
                }
            } compactLeading: {
                Image(systemName: context.state.problem != nil ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(context.state.problem != nil ? Theme.Colors.amber : Theme.Colors.wifi)
                    .accessibilityLabel(context.state.problem != nil ? "Board problem" : "Surveying")
            } compactTrailing: {
                SurveyActivityElapsed(attributes: context.attributes, state: context.state)
                    .font(Theme.Fonts.caption.monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.state.problem != nil ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(context.state.problem != nil ? Theme.Colors.amber : Theme.Colors.wifi)
            }
            .keylineTint(Theme.Colors.wifi)
        }
    }
}
