import SurveyCore
import SwiftUI

/// The navigation title with the shown survey as a subtitle; tapping it
/// picks another survey. Used as the principal toolbar item on Map and Lists.
struct SessionTitle: View {
    let title: String
    @Environment(SurveyData.self) private var data

    var body: some View {
        @Bindable var data = data
        Menu {
            Picker("Survey", selection: $data.pickedSessionID) {
                Text("Latest survey").tag(String?.none)
                ForEach(data.sessions) { session in
                    Text(Self.title(session)).tag(Optional(session.id))
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
        guard let session = data.session else { return "No surveys yet" }
        if data.pickedSessionID == nil {
            return session.stoppedAt == nil ? "This survey" : "Latest: \(DataFormat.dateTime(session.startedAt))"
        }
        return Self.title(session)
    }

    static func title(_ session: SessionRow) -> String {
        let date = DataFormat.dateTime(session.startedAt)
        return session.stoppedAt == nil ? "\(date) (recording)" : date
    }
}

/// Shown when there is no session to display.
struct NoSurveyView: View {
    let message: String
    @Environment(SurveyData.self) private var data

    var body: some View {
        if let error = data.loadError {
            ContentUnavailableView("Could not read surveys", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else {
            ContentUnavailableView {
                Label("No surveys yet", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                Text(message)
            }
        }
    }
}
