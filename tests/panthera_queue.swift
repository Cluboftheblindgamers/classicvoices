import Foundation
@testable import ClassicPortTest

private final class ResultBox: @unchecked Sendable { var accepted = true }
@main struct PantheraQueueCheck {
    static func main() {
        let cache = PhraseCache(budgetSeconds: 2, longestSeconds: 1, sampleRate: 100)
        cache.put("a", [Float](repeating: 1, count: 40))
        cache.put("b", [Float](repeating: 2, count: 40))
        cache.put("c", [Float](repeating: 3, count: 100))
        precondition(cache.get("a") != nil)
        cache.put("d", [Float](repeating: 4, count: 40))
        precondition(cache.get("a") != nil && cache.get("d") != nil)
        precondition(cache.get("b") == nil && cache.get("c") == nil)
        cache.put("too long", [Float](repeating: 0, count: 101))
        precondition(cache.get("too long") == nil)
        cache.shrink(to: 0)
        precondition(cache.get("a") == nil)

        let queue = PCMQueue(capacity: 1024)
        let old = queue.begin()
        let samples = [Float](repeating: 0.25, count: 100)
        precondition(samples.withUnsafeBufferPointer { queue.write($0.baseAddress!, count: $0.count, token: old) })
        let current = queue.begin()
        precondition(!samples.withUnsafeBufferPointer { queue.write($0.baseAddress!, count: $0.count, token: old) })
        queue.finish(old)  // a stale completion must not finish the new request
        var output = [Float](repeating: -1, count: 200)
        let empty = output.withUnsafeMutableBufferPointer { queue.read(into: $0.baseAddress!, max: $0.count, wait: 0) }
        precondition(empty.frames == 0 && !empty.complete)
        precondition(samples.withUnsafeBufferPointer { queue.write($0.baseAddress!, count: $0.count, token: current) })
        queue.finish(current)
        let read = output.withUnsafeMutableBufferPointer { queue.read(into: $0.baseAddress!, max: $0.count, wait: 0) }
        precondition(read.frames == 100 && read.complete && output[..<100].allSatisfy { $0 == 0.25 })

        let blocked = queue.begin()
        let started = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global().async {
            let large = [Float](repeating: 0.5, count: 4096)
            started.signal()
            result.accepted = large.withUnsafeBufferPointer { queue.write($0.baseAddress!, count: $0.count, token: blocked) }
            ended.signal()
        }
        precondition(started.wait(timeout: .now() + 1) == .success)
        queue.cancel()
        precondition(ended.wait(timeout: .now() + 1) == .success && !result.accepted)
        let first = queue.begin()
        let other = PCMQueue(capacity: 1024)
        _ = other.begin()
        precondition(PCMQueue.supersede(except: other))
        precondition(!queue.isCurrent(first) && other.isActive)
        other.cancel()
        // Completed does not mean consumed; supersession must drop unread PCM.
        let buffered = queue.begin()
        precondition(samples.withUnsafeBufferPointer { queue.write($0.baseAddress!, count: $0.count, token: buffered) })
        queue.finish(buffered)
        _ = PCMQueue.supersede(except: other)
        let stale = output.withUnsafeMutableBufferPointer { queue.read(into: $0.baseAddress!, max: $0.count, wait: 0, expectedToken: buffered) }
        precondition(stale.frames == 0 && stale.complete)
        let next = queue.begin()
        precondition(samples.withUnsafeBufferPointer { queue.write($0.baseAddress!, count: $0.count, token: next) })
        let oldRead = output.withUnsafeMutableBufferPointer { queue.read(into: $0.baseAddress!, max: $0.count, wait: 0, expectedToken: buffered) }
        precondition(oldRead.frames == 0 && oldRead.complete)
        queue.cancel()

        var job = SpeechJob(); job.text = "window"
        var settings = SpeechSettings()
        let a = MacinTalkProvider.cacheKey(job, voiceKey: "mt106/Alex", settings: settings)
        precondition(a == MacinTalkProvider.cacheKey(job, voiceKey: "mt106/Alex", settings: settings))
        precondition(a != MacinTalkProvider.cacheKey(job, voiceKey: "mt105/Alex", settings: settings))
        var profile = PantheraSettings(); profile.inflection = 140; settings.macinTalk["snowleopard"] = profile
        precondition(a != MacinTalkProvider.cacheKey(job, voiceKey: "mt106/Alex", settings: settings))
        settings = SpeechSettings(); job.macinTalkGain = 0.8
        precondition(a != MacinTalkProvider.cacheKey(job, voiceKey: "mt106/Alex", settings: settings))
        job.macinTalkGain = 1; job.macinTalkPitchTenths = 1
        precondition(a != MacinTalkProvider.cacheKey(job, voiceKey: "mt106/Alex", settings: settings))
        settings = SpeechSettings()
        profile = PantheraSettings(); profile.acceptCommands = true; profile.resetCommands = false
        settings.macinTalk["snowleopard"] = profile
        precondition(!MacinTalkProvider.canCache(job, voiceKey: "mt106/Alex", settings: settings))
        profile.resetCommands = true; settings.macinTalk["snowleopard"] = profile
        precondition(MacinTalkProvider.canCache(job, voiceKey: "mt106/Alex", settings: settings))
        job.markNames = ["position"]
        precondition(!MacinTalkProvider.canCache(job, voiceKey: "mt106/Alex", settings: settings))
        print("PASS cache budgets, eviction, stale writes/completion, cancellation, cross-unit supersession and settings-sensitive cache keys")
    }
}
