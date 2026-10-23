import Foundation
import Synchronization

/// Fans values out to any number of `AsyncStream` subscribers.
///
/// With `replaysLatest`, a new subscriber first receives the last value sent,
/// and each subscriber buffers only the newest value (state such as discovery
/// lists). Without it buffers are unbounded, so a slow consumer never loses a
/// record but grows memory until it catches up.
///
/// Values are never yielded while `state` is locked: a subscriber that is
/// cancelled runs its termination handler under the stream's own lock, and that
/// handler takes `state`, so yielding under `state` could deadlock. `sendLock`
/// keeps concurrent sends in order instead; termination handlers never take it.
final class Broadcaster<Element: Sendable>: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
        var latest: Element?
        var finished = false
    }

    private let state = Mutex(State())
    private let sendLock = Mutex(())
    private let replaysLatest: Bool

    init(replaysLatest: Bool = false) {
        self.replaysLatest = replaysLatest
    }

    func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Element.self, bufferingPolicy: replaysLatest ? .bufferingNewest(1) : .unbounded
        )
        let id = UUID()
        sendLock.withLock { _ in
            let (accepted, latest) = state.withLock { state -> (Bool, Element?) in
                guard !state.finished else { return (false, nil) }
                state.continuations[id] = continuation
                return (true, replaysLatest ? state.latest : nil)
            }
            guard accepted else {
                continuation.finish()
                return
            }
            if let latest { continuation.yield(latest) }
        }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ value: Element) {
        sendLock.withLock { _ in
            let continuations = state.withLock { state in
                if replaysLatest { state.latest = value }
                return Array(state.continuations.values)
            }
            for continuation in continuations {
                continuation.yield(value)
            }
        }
    }

    func finish() {
        let continuations = state.withLock { state in
            state.finished = true
            defer { state.continuations = [:] }
            return Array(state.continuations.values)
        }
        continuations.forEach { $0.finish() }
    }
}
