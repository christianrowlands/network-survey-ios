import Foundation
import Observation
import SurveyCore

/// Which session the Map and Lists show: the one the user picked, else the
/// survey recording now. Between surveys they show nothing, so nobody mistakes
/// an old survey for what is around them now.
@Observable
final class SurveyData {
    @ObservationIgnored let store: SurveyStore
    private(set) var sessions: [SessionRow] = []
    /// A survey picked from the menu. Nil follows the survey recording now.
    var pickedSessionID: String?
    /// Set when the session list could not be read.
    private(set) var loadError: String?
    @ObservationIgnored private let live: @MainActor () -> SessionRow?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: SurveyStore, live: @escaping @MainActor () -> SessionRow? = { nil }) {
        self.store = store
        self.live = live
        let updates = store.observe { try StoreQueries.sessions($0) }
        task = Task { [weak self] in
            do {
                for try await sessions in updates {
                    self?.sessions = sessions
                }
            } catch is CancellationError {
            } catch {
                self?.loadError = error.localizedDescription
            }
        }
    }

    deinit {
        task?.cancel()
    }

    /// The survey recording now, if any.
    var liveSession: SessionRow? {
        guard let row = live() else { return nil }
        return sessions.first { $0.id == row.id } ?? row
    }

    var session: SessionRow? {
        if let pickedSessionID, let picked = sessions.first(where: { $0.id == pickedSessionID }) { return picked }
        return liveSession
    }

    var sessionID: String? { session?.id }

    /// A survey other than the one recording now is shown.
    var isShowingPast: Bool {
        guard let session else { return false }
        return session.id != live()?.id
    }

    /// Every survey but the one recording now, newest first.
    var pastSessions: [SessionRow] {
        let liveID = live()?.id
        return sessions.filter { $0.id != liveID }
    }

    var lastSession: SessionRow? { pastSessions.first }

    func showLast() {
        pickedSessionID = lastSession?.id
    }

    func showLive() {
        pickedSessionID = nil
    }
}
