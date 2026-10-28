import SurveyCore
import SwiftUI

/// The navigation title with the shown survey as a subtitle; tapping it
/// picks a past survey. Used as the principal toolbar item on Map and Lists.
struct SessionTitle: View {
    let title: String
    @Environment(SurveyData.self) private var data

    var body: some View {
        @Bindable var data = data
        Menu {
            Picker("Survey", selection: $data.pickedSessionID) {
                Text(data.liveSession == nil ? "Current survey" : "This survey (recording)").tag(String?.none)
                Section("Past surveys") {
                    ForEach(data.pastSessions) { session in
                        Text(DataFormat.dateTime(session.startedAt)).tag(Optional(session.id))
                    }
                }
            }
        } label: {
            VStack(spacing: 0) {
                Text(title)
                    .font(Theme.Fonts.sectionTitle)
                    .foregroundStyle(Theme.Colors.ink)
                HStack(spacing: Theme.Spacing.xxs) {
                    Text(subtitle)
                    if !data.sessions.isEmpty {
                        Image(systemName: "chevron.down").imageScale(.small)
                    }
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.Colors.ink2)
            }
        }
        .disabled(data.sessions.isEmpty)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityHint("Chooses which survey to show")
        .accessibilityIdentifier("session.title")
    }

    private var subtitle: String {
        guard let session = data.session else { return data.sessions.isEmpty ? "No surveys yet" : "Not recording" }
        return data.isShowingPast ? "Past: \(DataFormat.dateTime(session.startedAt))" : "Recording"
    }
}

/// Says the screen shows a finished survey, not what is around now, with a
/// way back. Shown at the top of Map and Lists.
struct PastSurveyBar: View {
    @Environment(SurveyData.self) private var data

    var body: some View {
        if data.isShowingPast, let session = data.session {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.Colors.amber)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Past survey")
                        .font(Theme.Fonts.sectionTitle)
                        .foregroundStyle(Theme.Colors.ink)
                    Text(DataFormat.dateTime(session.startedAt))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                Spacer(minLength: 0)
                Button("Close") { data.showLive() }
                    .font(Theme.Fonts.sectionTitle)
                    .accessibilityHint(data.liveSession == nil ? "Stops showing this survey" : "Shows the survey recording now")
                    .accessibilityIdentifier("pastSurvey.close")
            }
            .padding(.horizontal, Theme.Spacing.screenGutter)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity)
            .background(Theme.Colors.amberSoft)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pastSurvey.bar")
        }
    }
}

/// Shown when no survey is recording and none is picked, or there are none yet.
struct NoSurveyView: View {
    let message: String
    /// Offers Nearby Bluetooth, for the Bluetooth list.
    var offersNearby = false
    @Environment(SurveyData.self) private var data
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = data.loadError {
            ContentUnavailableView("Could not read surveys", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ContentUnavailableView {
                if data.sessions.isEmpty {
                    Label("No surveys yet", systemImage: "dot.radiowaves.left.and.right")
                } else {
                    Label("Not recording", systemImage: "pause.circle")
                }
            } description: {
                Text(message)
            } actions: {
                Button("Go to Survey") { model.selectedTab = .survey }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.Colors.onAccent)
                    .accessibilityIdentifier("noSurvey.goToSurvey")
                if let last = data.lastSession {
                    Button("Show last survey (\(DataFormat.dateTime(last.startedAt)))") { data.showLast() }
                        .accessibilityIdentifier("noSurvey.showLast")
                }
                if offersNearby && model.survey.state == .idle {
                    NearbyButton()
                }
            }
        }
    }
}
