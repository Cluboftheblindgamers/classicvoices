// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation
import OSLog

/// Audio between the synthesis thread (producer) and the render block
/// (consumer), for one request at a time.
///
/// Every request gets a token; cancelling bumps it, so a producer still
/// pulling for an abandoned request finds out at its next write and stops,
/// and nothing it produced is ever played.
///
/// The render side may wait briefly for audio. That is acceptable here
/// because a speech provider is rendered by the system's speech service on
/// demand, not on a hardware I/O deadline; how long it tolerates a wait is one
/// of the things to measure on a device (docs/ios-port.md).
final class PCMQueue: @unchecked Sendable {
    private let condition = NSCondition()
    /// Raw storage, copied in and out with memcpy (at most two runs each way)
    /// while the lock is held -- the render thread waits on the same lock, so
    /// a sample-at-a-time loop with an index modulo and Swift's exclusivity
    /// checks on every access was time taken from both threads.
    private let ring: UnsafeMutablePointer<Float>
    private let capacity: Int
    private var head = 0          // next read
    private var count = 0
    private var token: UInt64 = 0
    private var active = false    // a producer is (or is about to be) working
    private var finished = true   // no more audio is coming for `token`
    private var reads: UInt64 = 0 // frames-delivering reads so far, to tell a stalled consumer
    // How the current request played, for its "play" line (diagnostic builds):
    // a word cut off on the iPhone left no trace in the timing line, which
    // ends when the audio is made, not when it is heard (the owner, Nov 5).
    private var played = 0, shortReads = 0, longestWait = 0.0, reported = false
    private static let playLog = Logger(subsystem: "com.pantheraspeech", category: "play")

    init(capacity: Int) {
        self.capacity = max(capacity, 1024)
        // Not zeroed: only slots `write` filled are ever read, and Float is
        // trivial, so `update` may write into it as it is.  Zeroing touched
        // every page of the 700 KB at once; now a page costs memory only
        // once a request has run that far ahead (every request starts at
        // slot 0, and most are a second or two).
        ring = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity)
        Self.registry.lock()
        Self.all.append(Weak(self))
        Self.all.removeAll { $0.queue == nil }
        Self.registry.unlock()
    }

    deinit {
        ring.deallocate()
    }

    // MARK: - Every queue in this process

    private final class Weak { weak var queue: PCMQueue?; init(_ q: PCMQueue) { queue = q } }
    private static let registry = NSLock()
    nonisolated(unsafe) private static var all: [Weak] = []

    /// A new request on any audio unit of this process supersedes whatever
    /// another unit's queue is still holding: there is one engine, and it
    /// speaks one thing at a time.  True if one was cancelled (its producer
    /// may be waiting and needs the engine stopped).
    static func supersede(except mine: PCMQueue) -> Bool {
        registry.lock()
        let others = all.compactMap(\.queue).filter { $0 !== mine }
        registry.unlock()
        var any = false
        for q in others { any = q.cancel(reason: "superseded by another unit") || any }
        return any
    }

    var isActive: Bool {
        condition.lock(); defer { condition.unlock() }
        return active
    }

    /// A new request. Returns its token.
    func begin() -> UInt64 {
        condition.lock(); defer { condition.unlock() }
        token &+= 1
        head = 0; count = 0
        active = true
        finished = false
        played = 0; shortReads = 0; longestWait = 0; reported = false
        condition.broadcast()
        return token
    }

    /// Drop everything. True when a producer was working and needs stopping.
    @discardableResult
    func cancel(reason: String = "cancelled") -> Bool {
        condition.lock(); defer { condition.unlock() }
        if !reported && (active || count > 0) { reportPlay(reason) }
        let wasActive = active
        token &+= 1
        head = 0; count = 0
        active = false
        finished = true
        condition.broadcast()
        return wasActive
    }

    func isCurrent(_ t: UInt64) -> Bool {
        condition.lock(); defer { condition.unlock() }
        return t == token
    }

    /// The producer is done with request `t`, normally or not.
    func finish(_ t: UInt64) {
        condition.lock(); defer { condition.unlock() }
        guard t == token else { return }
        active = false
        finished = true
        condition.broadcast()
    }

    /// How long a full queue may go unread before the request is taken as
    /// abandoned.  The system can drop an audio unit -- when the phone locks,
    /// it suspends the voice and makes a new unit on unlock -- without
    /// cancelling what it was speaking; waiting for room for ever then left
    /// the one engine thread stuck, and every later request queued behind it
    /// in silence until VoiceOver was restarted.
    /// A long backstop only -- a request paused with VoiceOver's two-finger
    /// tap stops being read too -- for a dropped unit that is never freed;
    /// `supersede` is what normally ends such a request.
    static let stallLimit: TimeInterval = 30

    /// Producer: append samples, waiting for room. False if `t` was cancelled,
    /// or nobody has read anything for `stallLimit` seconds.
    func write(_ samples: UnsafePointer<Float>, count n: Int, token t: UInt64) -> Bool {
        var done = 0
        condition.lock(); defer { condition.unlock() }
        while done < n {
            guard t == token else { return false }
            let room = capacity - count
            if room == 0 {
                let seen = reads
                let deadline = Date(timeIntervalSinceNow: Self.stallLimit)
                while capacity - count == 0 && t == token && reads == seen {
                    if !condition.wait(until: deadline) { break }
                }
                if capacity - count == 0 && t == token && reads == seen {
                    // Abandoned: end the request as a cancel would.
                    token &+= 1
                    head = 0; count = 0
                    active = false
                    finished = true
                    condition.broadcast()
                    return false
                }
                continue
            }
            let chunk = min(room, n - done)
            let tail = (head + count) % capacity              // first free slot
            let first = min(chunk, capacity - tail)           // up to the end of storage
            (ring + tail).update(from: samples + done, count: first)
            if chunk > first { ring.update(from: samples + done + first, count: chunk - first) }
            count += chunk
            done += chunk
            condition.broadcast()
        }
        return true
    }

    /// Consumer: copy up to `max` frames into `out`, waiting up to `wait`
    /// seconds for all of them (or for the request to end). `complete` is
    /// true once the request has ended and everything it produced has been
    /// read.
    ///
    /// It waits for a *full* buffer, not just the first frame: the system's
    /// speech renderer treats every buffer it pulls as full, so a short one
    /// is played with whatever was left in the rest of it.  That was the
    /// buzz heard at every VoiceOver rate but 50% on the first Mac test.
    func read(into out: UnsafeMutablePointer<Float>, max: Int, wait: TimeInterval, expectedToken: UInt64? = nil) -> (frames: Int, complete: Bool) {
        condition.lock(); defer { condition.unlock() }
        let current = expectedToken ?? token
        guard token == current else { return (0, true) }
        let asked = Date()
        if count < max && !finished {
            let deadline = Date(timeIntervalSinceNow: wait)
            while token == current && count < max && !finished && condition.wait(until: deadline) {}
        }
        guard token == current else { return (0, true) }
        longestWait = Swift.max(longestWait, Date().timeIntervalSince(asked))
        let n = min(max, count)
        // Short while more is still coming: the rest of this buffer plays as
        // silence in the middle of the utterance.
        if n < max && !finished { shortReads += 1 }
        played += n
        let first = min(n, capacity - head)
        out.update(from: ring + head, count: first)
        if n > first { (out + first).update(from: ring, count: n - first) }
        head = (head + n) % capacity
        count -= n
        if n > 0 { reads &+= 1; condition.broadcast() }
        if finished && count == 0 && !reported && played > 0 { reportPlay("played to the end") }
        return (n, finished && count == 0)
    }

    /// One line per request when its playing ends.  Lock held.
    private func reportPlay(_ how: String) {
        reported = true
        #if !PANTHERA_PUBLIC || PANTHERA_DIAGNOSTICS
        let line = String(format: "play %@: %.2f s played, %d short reads, longest wait %.0f ms",
                          how, Double(played) / 22050.0, shortReads, longestWait * 1000)
        Self.playLog.notice("\(line, privacy: .public)")
        #endif
    }
}
