/// A FIFO for messages waiting to be streamed, with the Network Survey Android
/// app's limit semantics: `limit` counts queued plus in-flight messages, a full
/// queue drops new messages (counted in `dropped`), and a limit of 0 means
/// unbounded.
struct StreamQueue<Element> {
    var limit: Int
    private var storage: [Element] = []
    private var head = 0
    private(set) var inFlight = 0
    private(set) var dropped = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Queued plus in flight.
    var depth: Int { storage.count - head + inFlight }
    var isEmpty: Bool { storage.count == head }

    /// Adds a message; returns false (and counts a drop) when the queue is full.
    /// `limitOverride` replaces an unbounded limit, for example while a broker
    /// has never been reached.
    @discardableResult
    mutating func append(_ element: Element, limitOverride: Int? = nil) -> Bool {
        let bound = limit > 0 ? limit : (limitOverride ?? 0)
        if bound > 0 && depth >= bound {
            dropped += 1
            return false
        }
        storage.append(element)
        return true
    }

    /// Removes up to `count` messages and counts them as in flight.
    mutating func take(_ count: Int) -> [Element] {
        let end = min(storage.count, head + count)
        let taken = Array(storage[head..<end])
        head = end
        inFlight += taken.count
        if head > 1024 && head * 2 > storage.count {
            storage.removeFirst(head)
            head = 0
        }
        return taken
    }

    /// In-flight messages that were delivered.
    mutating func finished(_ count: Int) {
        inFlight = max(0, inFlight - count)
    }

    /// In-flight messages that failed go back to the front, in order.
    mutating func requeue(_ elements: [Element]) {
        inFlight = max(0, inFlight - elements.count)
        storage.replaceSubrange(head..<head, with: elements)
    }

    mutating func removeAll() {
        storage = []
        head = 0
        inFlight = 0
    }
}
