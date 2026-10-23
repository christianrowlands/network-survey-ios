import Foundation

/// Sends record uploads (`api/v1/device/upload`) as file-based upload tasks,
/// which is what a background `URLSession` requires; the system then finishes
/// them even when the app is suspended after a survey stops. Create it with
/// `URLSessionConfiguration.background(withIdentifier:)` once at launch (and
/// again from `handleEventsForBackgroundURLSession`). Answers for uploads the
/// app no longer waits for (it was relaunched meanwhile) go to
/// `orphanHandler`, which should call `NSAnalyticsUploader.completeBackgroundUpload`;
/// answers that arrive before the handler is set are kept until it is.
/// Every other request (registration, status, unregister) goes through
/// `fallbackSession` in the foreground: a registration answer must reach the
/// caller, because its token can be used only once.
public final class BackgroundUploadTransport: NSObject, NSAnalyticsTransport, URLSessionDataDelegate, @unchecked Sendable {
    public typealias Completion = Result<(Data, HTTPURLResponse), Error>

    private let lock = NSLock()
    private var session: URLSession!
    private let fallback: URLSessionTransport
    private let directory: URL
    private var waiting: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private var received: [Int: Data] = [:]
    private var orphanHandlerStorage: (@Sendable (String, Completion) -> Void)?
    private var eventsFinishedStorage: (@Sendable () -> Void)?
    private var unclaimed: [(String, Completion)] = []
    private var eventsFinishedUnclaimed = false

    /// Called with the task ID (the batch ID) of an upload that finished while
    /// nobody was waiting for it.
    public var orphanHandler: (@Sendable (String, Completion) -> Void)? {
        get { lock.withLock { orphanHandlerStorage } }
        set {
            let pending = lock.withLock {
                orphanHandlerStorage = newValue
                defer { if newValue != nil { unclaimed = [] } }
                return newValue == nil ? [] : unclaimed
            }
            for (taskID, result) in pending { newValue?(taskID, result) }
        }
    }

    /// Called once when the system has delivered all events for a background
    /// session; set it to the completion handler from
    /// `handleEventsForBackgroundURLSession`. It is cleared after the call. If
    /// the events finished before it was set, the new closure runs right away.
    public var eventsFinished: (@Sendable () -> Void)? {
        get { lock.withLock { eventsFinishedStorage } }
        set {
            let runNow = lock.withLock { () -> Bool in
                if newValue != nil && eventsFinishedUnclaimed {
                    eventsFinishedUnclaimed = false
                    eventsFinishedStorage = nil
                    return true
                }
                eventsFinishedStorage = newValue
                return false
            }
            if runNow { newValue?() }
        }
    }

    /// `directory` holds the request bodies until the system has sent them, so
    /// it must survive app termination: the default is
    /// `Application Support/NSAnalytics/uploads`, excluded from backups.
    public init(configuration: URLSessionConfiguration, fallbackSession: URLSession = .shared, directory: URL? = nil) {
        fallback = URLSessionTransport(session: fallbackSession)
        self.directory = directory ?? Self.defaultDirectory()
        super.init()
        var folder = self.directory  // setResourceValues is mutating
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        removeAbandonedFiles()
    }

    static func defaultDirectory() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("NSAnalytics/uploads", isDirectory: true)
    }

    /// Deletes body files older than an hour that no task of the session uses.
    private func removeAbandonedFiles() {
        let directory = directory
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap(\.taskDescription))
            let cutoff = Date().addingTimeInterval(-3600)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files where !live.contains(file.deletingPathExtension().lastPathComponent) {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
    }

    public func send(_ request: URLRequest, body: Data, taskID: String) async throws -> (Data, HTTPURLResponse) {
        guard !body.isEmpty, request.url?.path.hasSuffix("/device/upload") == true else {
            return try await fallback.send(request, body: body, taskID: taskID)
        }
        let file = directory.appendingPathComponent("\(taskID).json")
        try body.write(to: file, options: .atomic)
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = taskID
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiting[task.taskIdentifier] = continuation }
            task.resume()
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { received[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskDescription ?? ""
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(taskID).json"))
        let data = lock.withLock { received.removeValue(forKey: task.taskIdentifier) ?? Data() }
        let result: Completion
        if let error {
            result = .failure(error)
        } else if let response = task.response as? HTTPURLResponse {
            result = .success((data, response))
        } else {
            result = .failure(URLError(.badServerResponse))
        }
        // Decided under the lock, so a handler set concurrently cannot miss it.
        let (continuation, orphan) = lock.withLock {
            let continuation = waiting.removeValue(forKey: task.taskIdentifier)
            if continuation == nil && orphanHandlerStorage == nil { unclaimed.append((taskID, result)) }
            return (continuation, orphanHandlerStorage)
        }
        if let continuation {
            continuation.resume(with: result)
        } else {
            orphan?(taskID, result)
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock {
            defer { eventsFinishedStorage = nil }
            if eventsFinishedStorage == nil { eventsFinishedUnclaimed = true }
            return eventsFinishedStorage
        }
        handler?()
    }
}
