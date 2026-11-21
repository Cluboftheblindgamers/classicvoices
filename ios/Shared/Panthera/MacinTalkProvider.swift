import Foundation
import CryptoKit

/// MacinTalk's engine work stays on one serial producer. Cached requests have
/// a separate producer, so an earlier engine cancellation cannot delay them.
/// Every writer carries PCMQueue's request token; late writers cannot publish.
final class MacinTalkProvider: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "classicvoices.macintalk", qos: .userInteractive)
    private static let cacheQueue = DispatchQueue(label: "classicvoices.macintalk.cache", qos: .userInteractive)
    private static let engine = VoiceEngine()
    private let pcm = PCMQueue(capacity: 22050 * 8)
    private let markerLock = NSLock()
    private var markerToken: UInt64 = 0
    private var markers: [(id: Int, frame: Int)] = []
    struct Metrics: Sendable {
        var token: UInt64 = 0
        var firstMs = -1.0
        var totalMs = 0.0
        var frames = 0
        var complete = false
        var cached = false
        var error = ""
    }
    private let metricsLock = NSLock()
    private var currentMetrics = Metrics()
    var metrics: Metrics { metricsLock.lock(); defer { metricsLock.unlock() }; return currentMetrics }
    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
    private func record(_ token: UInt64, start: Double, samples: UnsafeBufferPointer<Float>? = nil,
                        complete: Bool = false, cached: Bool = false, error: String = "") {
        guard pcm.isCurrent(token) else { return }
        metricsLock.lock(); defer { metricsLock.unlock() }
        guard currentMetrics.token == token else { return }
        if let samples {
            if currentMetrics.firstMs < 0 && samples.contains(where: { abs($0) >= 0.001 }) {
                currentMetrics.firstMs = Self.now() - start
            }
            currentMetrics.frames += samples.count
        }
        currentMetrics.totalMs = Self.now() - start
        currentMetrics.complete = complete; currentMetrics.cached = cached; currentMetrics.error = error
    }

    deinit { pcm.cancel(reason: "audio unit released") }

    static func preload(_ key: String, settings: SpeechSettings) {
        queue.async { engine.preload(key) }
    }

    func supersedeOtherRequests() { _ = PCMQueue.supersede(except: pcm) }

    func submit(_ job: SpeechJob, voiceKey: String, settings: SpeechSettings) {
        let start = Self.now()
        EngineWatch.requestArrived()
        supersedeOtherRequests()
        let token = pcm.begin()
        metricsLock.lock(); currentMetrics = Metrics(token: token); metricsLock.unlock()
        markerLock.lock(); markerToken = token; markers = []; markerLock.unlock()
        let cache = PhraseCache.shared
        let key = Self.cacheKey(job, voiceKey: voiceKey, settings: settings)
        let cacheable = Self.canCache(job, voiceKey: voiceKey, settings: settings)
        if cacheable, let samples = cache.get(key) {
            Self.cacheQueue.async { [self] in
                defer { pcm.finish(token); record(token, start: start, complete: true, cached: true) }
                samples.withUnsafeBufferPointer { samples in
                    var at = 0
                    while at < samples.count && pcm.isCurrent(token) {
                        let count = min(2048, samples.count - at)
                        guard pcm.write(samples.baseAddress! + at, count: count, token: token) else { return }
                        record(token, start: start, samples: UnsafeBufferPointer(start: samples.baseAddress! + at, count: count), cached: true)
                        at += count
                    }
                }
            }
            return
        }
        Self.queue.async { [self] in
            guard pcm.isCurrent(token) else { return }
            EngineWatch.enter("MacinTalk request")
            defer { pcm.finish(token); EngineWatch.idle() }
            let engine = Self.engine
            guard let stream = engine.stream else { return }
            engine.speak(job, voiceKey: voiceKey,
                         resetCommands: settings.resetCommands,
                         twentyFourHour: settings.twentyFourHour, modernRate: settings.modernRate,
                         settings: settings)
            var audio = [Float](repeating: 0, count: 4096)
            var collected: [Float]? = cacheable ? [] : nil
            while pcm.isCurrent(token) {
                var done: Int32 = 0
                let count = audio.withUnsafeMutableBufferPointer { vxs_read(stream, $0.baseAddress, $0.count, &done) }
                var emitted = [VxsMark](repeating: VxsMark(), count: 16)
                let markerCount = emitted.withUnsafeMutableBufferPointer { vxs_read_marks(stream, $0.baseAddress, $0.count) }
                if markerCount > 0 {
                    markerLock.lock()
                    if markerToken == token {
                        markers += emitted[..<markerCount].map { (Int($0.id), Int($0.frame)) }
                    }
                    markerLock.unlock()
                }
                if count > 0 {
                    if collected != nil {
                        if collected!.count + count <= cache.longest { collected!.append(contentsOf: audio[..<count]) }
                        else { collected = nil }
                    }
                    EngineWatch.enter("MacinTalk audio delivery")
                    let accepted = audio.withUnsafeBufferPointer { pcm.write($0.baseAddress!, count: count, token: token) }
                    if !accepted { break }
                    audio.withUnsafeBufferPointer { record(token, start: start, samples: UnsafeBufferPointer(rebasing: $0[..<count])) }
                }
                if done != 0 {
                    if pcm.isCurrent(token), String(cString: vxs_last_error(stream)).isEmpty,
                       let collected, !collected.isEmpty { cache.put(key, collected) }
                    record(token, start: start, complete: true, error: String(cString: vxs_last_error(stream)))
                    return
                }
                if count == 0 { vxs_wait(stream, 5000) }
            }
            // Only this serial queue touches this engine. Waiting for its
            // cancellation cannot block the audio-unit request callback or cache.
            engine.cancel()
        }
    }

    func cancel() {
        pcm.cancel()
        metricsLock.lock(); currentMetrics.token &+= 1; currentMetrics.complete = true; currentMetrics.error = "Cancelled"; metricsLock.unlock()
        markerLock.lock(); markerToken &+= 1; markers = []; markerLock.unlock()
    }
    func read(into output: UnsafeMutablePointer<Float>, count: Int, wait: TimeInterval = 0.5) -> (frames: Int, complete: Bool) {
        pcm.read(into: output, max: count, wait: wait)
    }
    func takeMarkers() -> [(id: Int, frame: Int)] {
        markerLock.lock(); defer { markerLock.unlock() }
        let out = markers; markers = []; return out
    }

    static func canCache(_ job: SpeechJob, voiceKey: String, settings: SpeechSettings) -> Bool {
        guard job.markNames.isEmpty else { return false }
        // Persistent embedded commands make future audio depend on engine
        // history. Replaying cached PCM would skip those state changes.
        if settings.macinTalkCompatibility, let generation = MacinTalkCompatibility.generation(for: voiceKey) {
            let profile = settings.macinTalkSettings(generation)
            if profile.acceptCommands && !profile.resetCommands { return false }
        } else if !settings.resetCommands { return false }
        return true
    }

    static func cacheKey(_ job: SpeechJob, voiceKey: String, settings: SpeechSettings) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(settings)) ?? Data()
        data.append(Data("\(VoiceCatalog.dataRevision)|\(voiceKey)|\(job.rate)|\(job.pitch)|\(job.volume)|\(job.trailingPauseMs)|\(job.macinTalkWPM ?? 0)|\(job.macinTalkGain)|\(job.macinTalkPitchTenths ?? 10000)|\(job.text)".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
