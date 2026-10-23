import Foundation
import Observation
import SurveyCore

/// Which session the Map and Lists show: the one the user picked, else the
/// newest (the running one while a survey is on).
@Observable
final class SurveyData {
    @ObservationIgnored let store: SurveyStore
    private(set) var sessions: [SessionRow] = []
    /// Nil follows the newest session.
    var pickedSessionID: String?
    /// Set when the session list could not be read.
    private(set) var loadError: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(store: SurveyStore) {
        self.store = store
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

    var session: SessionRow? {
        if let pickedSessionID, let picked = sessions.first(where: { $0.id == pickedSessionID }) { return picked }
        return sessions.first
    }

    var sessionID: String? { session?.id }
}
