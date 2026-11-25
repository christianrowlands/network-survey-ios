import SurveyCore
import SwiftUI

/// After Stop: the survey's files, ready to share, until the next survey
/// starts or the user closes it.
struct FinishedSurveyPanel: View {
    let session: SessionRow
    @Environment(AppModel.self) private var model
    @State private var folder: SurveyFolder?

    var body: some View {
        NoticePanel(symbol: "checkmark.circle", title: "Survey saved", message: message, tone: .info) {
            if let folder, !folder.files.isEmpty {
                ShareLink(items: folder.files.map(\.url)) {
                    Label("Share files", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("survey.shareFiles")
            }
            Button("See files") { model.surveyPath.append(.files) }
                .accessibilityIdentifier("survey.seeFiles")
            Button("Close") { model.finishedSurvey = nil }
                .accessibilityIdentifier("survey.closeFinished")
        }
        .accessibilityIdentifier("survey.finished")
        .task(id: session.id) {
            let root = model.filesRoot
            let session = session
            folder = await Task.detached(priority: .utility) {
                SurveyFiles.folders(root: root, sessions: [session]).first { $0.session?.id == session.id }
            }.value
        }
    }

    private var message: String {
        let started = DataFormat.dateTime(session.startedAt)
        guard let folder else { return "Started \(started)." }
        let count = folder.files.count
        return "Started \(started). \(count) \(count == 1 ? "file" : "files"), \(DataFormat.bytes(folder.totalBytes))."
    }
}
