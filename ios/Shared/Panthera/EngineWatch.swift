// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation
import os

/// Which step the engine thread is in, and for how long -- so a voice that
/// goes silent leaves a line in the log saying where it stopped.
///
/// A request writes its timing line only when it ends; a request that never
/// ends wrote nothing, and a log of a voice gone quiet after an unlock could
/// not tell "VoiceOver sent nothing" from "the engine is stuck in X".
/// Diagnostic only: nothing here stops, cancels or restarts anything.
enum EngineWatch {
    private static let lock = NSLock()
    private static let log = Logger(subsystem: "com.pantheraspeech", category: "watch")
    /// Longer than anything a working request does on the engine thread
    /// between two steps (a pull waits at most 10 s, a full queue 30 s).
    static let stuckAfter: UInt64 = 40

    // All touched only under `lock`.
    nonisolated(unsafe) private static var stage = "idle"
    nonisolated(unsafe) private static var busy = false
    nonisolated(unsafe) private static var since: UInt64 = 0
    nonisolated(unsafe) private static var reported = false   // this stall is already logged
    nonisolated(unsafe) private static var arrivals = 0       // requests that came in during it
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?

    private static var footprint: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? "\(info.phys_footprint >> 20) MB" : "unavailable"
    }

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// The engine thread enters `name`.
    static func enter(_ name: String) { move(to: name, busy: true) }

    /// The engine thread is done with the request.
    static func idle() { move(to: "idle", busy: false) }

    private static func move(to name: String, busy nowBusy: Bool) {
        let t = now
        lock.lock()
        let ended: (String, UInt64, Int)? = reported ? (stage, (t - since) / 1_000_000_000, arrivals) : nil
        stage = name; busy = nowBusy; since = t; reported = false; arrivals = 0
        if timer == nil { timer = makeTimer() }
        // One shot, only while a request is on the engine thread: an idle
        // voice (iOS keeps one running through a lock) is never woken.
        timer?.schedule(deadline: nowBusy ? DispatchTime.now() + .seconds(Int(stuckAfter) + 1) : DispatchTime.distantFuture,
                        leeway: .seconds(2))
        lock.unlock()
        if case let (was, seconds, count)? = ended {
            log.error("engine moved on after \(seconds) s in \(was, privacy: .public); \(count) requests arrived meanwhile")
        }
    }

    /// A request arrived from the system.  Counted, and logged once, when the
    /// engine thread has been stuck: whether anything was asked of it is half
    /// of what such a log has to answer.
    static func requestArrived() {
        let t = now
        lock.lock()
        var first: (String, UInt64)?
        if reported {
            arrivals += 1
            if arrivals == 1 { first = (stage, (t - since) / 1_000_000_000) }
        }
        lock.unlock()
        if case let (name, seconds)? = first {
            log.error("request arrived while the engine has been \(seconds) s in \(name, privacy: .public)")
        }
    }

    private static func makeTimer() -> DispatchSourceTimer {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .distantFuture)
        source.setEventHandler { check() }
        source.resume()
        return source
    }

    private static func check() {
        let t = now
        lock.lock()
        var stuck: (String, UInt64)?
        if busy && !reported {
            let seconds = (t - since) / 1_000_000_000
            if seconds >= stuckAfter { reported = true; stuck = (stage, seconds) }
        }
        lock.unlock()
        if case let (name, seconds)? = stuck {
            log.error("engine stuck \(seconds) s in \(name, privacy: .public), memory \(footprint, privacy: .public)")
        }
    }
}
