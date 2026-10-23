import BoardKit
import BoardProtocol
import Foundation

/// Turns board timestamps into wall time.
///
/// After SetTime a board reports epoch milliseconds (`time_synced`). Before
/// that (or after a board reset) it reports milliseconds since boot; the offset
/// to wall time is then learned from its 1 Hz status. Without either, the time
/// the phone received the record is used.
struct BoardClock {
    /// Wall time minus board time, in seconds, per unsynced board.
    private var offsets: [BoardID: TimeInterval] = [:]
    /// A synced time further than this from the receive time is not trusted.
    var maxSkew: TimeInterval = 24 * 3600

    mutating func noteStatus(_ status: NSBBoardStatus, from board: BoardID, receivedAt: Date) {
        if status.timeSynced || status.boardTimeMs == 0 {
            offsets[board] = nil
        } else {
            offsets[board] = receivedAt.timeIntervalSince1970 - Double(status.boardTimeMs) / 1000
        }
    }

    mutating func forget(_ board: BoardID) {
        offsets[board] = nil
    }

    func wallTime(boardTimeMs: UInt64, synced: Bool, board: BoardID, receivedAt: Date) -> Date {
        guard boardTimeMs > 0 else { return receivedAt }
        if synced {
            let date = Date(timeIntervalSince1970: Double(boardTimeMs) / 1000)
            return abs(date.timeIntervalSince(receivedAt)) <= maxSkew ? date : receivedAt
        }
        if let offset = offsets[board] {
            let date = Date(timeIntervalSince1970: offset + Double(boardTimeMs) / 1000)
            // A record cannot be from the future; clamp small clock jitter.
            return min(date, receivedAt)
        }
        return receivedAt
    }
}

/// Recent fixes from one source, for finding the fix closest to a record's
/// time. Records that a board buffered while disconnected arrive late and are
/// still placed where they were observed.
struct LocationHistory {
    private(set) var samples: [LocationSample] = []
    let capacity: Int

    init(capacity: Int = 1800) {
        self.capacity = capacity
    }

    var latest: LocationSample? { samples.last }

    mutating func append(_ sample: LocationSample) {
        if let last = samples.last, sample.timestamp < last.timestamp {
            let index = samples.firstIndex { $0.timestamp > sample.timestamp } ?? samples.endIndex
            samples.insert(sample, at: index)
        } else {
            samples.append(sample)
        }
        // Trim in chunks so appends stay cheap.
        if samples.count > capacity + capacity / 8 { samples.removeFirst(samples.count - capacity) }
    }

    /// The sample nearest in time to `date`.
    func nearest(to date: Date) -> LocationSample? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].timestamp < date { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return samples[0] }
        if low == samples.count { return samples[low - 1] }
        let before = samples[low - 1], after = samples[low]
        return date.timeIntervalSince(before.timestamp) <= after.timestamp.timeIntervalSince(date) ? before : after
    }
}

extension LocationSample {
    /// Typical GPS user equivalent range error, to turn HDOP into meters.
    static let gpsUERE = 5.0

    /// A board GPS fix, or nil when the fix is invalid.
    init?(_ fix: NSBGpsFix, wallTime: Date) {
        guard fix.fixQuality > 0, fix.latitude != 0 || fix.longitude != 0,
              abs(fix.latitude) <= 90, abs(fix.longitude) <= 180 else { return nil }
        self.init(
            latitude: fix.latitude,
            longitude: fix.longitude,
            altitude: fix.hasAltitudeM ? Double(fix.altitudeM) : nil,
            horizontalAccuracy: fix.hasHdop ? Double(fix.hdop) * Self.gpsUERE : nil,
            speed: fix.hasSpeedMps ? Double(fix.speedMps) : nil,
            course: fix.hasCourseDeg ? Double(fix.courseDeg) : nil,
            timestamp: fix.fixTimeMs > 0 ? Date(timeIntervalSince1970: Double(fix.fixTimeMs) / 1000) : wallTime,
            source: .boardGPS
        )
    }
}
