import Foundation
@testable import ClassicPortTest

@main struct ProviderIntegration {
    static func milliseconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
    static func collect(_ provider: MacinTalkProvider, limit: Double = 12) -> (audio: [Float], first: Double, total: Double) {
        let start = milliseconds()
        var out: [Float] = [], buffer = [Float](repeating: 0, count: 1024)
        var first = -1.0
        while milliseconds() - start < limit * 1000 {
            let read = buffer.withUnsafeMutableBufferPointer { provider.read(into: $0.baseAddress!, count: $0.count) }
            if read.frames > 0 {
                if first < 0 { first = milliseconds() - start }
                out.append(contentsOf: buffer[..<read.frames])
            }
            if read.complete { return (out, first, milliseconds() - start) }
        }
        provider.cancel()
        preconditionFailure("provider did not finish within \(limit) seconds")
    }
    static func main() {
        let settings = SpeechSettings(), key = "mt106/Alex"
        let provider = MacinTalkProvider()
        func job(_ text: String) -> SpeechJob {
            SpeechJob.from(ssml: "<speak>\(text)</speak>", voiceKey: key, settings: settings)
        }
        let label = job("TextEdit, window.")
        provider.submit(label, voiceKey: key, settings: settings)
        let live = collect(provider)
        precondition(!live.audio.isEmpty)
        provider.submit(label, voiceKey: key, settings: settings)
        let cached = collect(provider)
        precondition(cached.audio == live.audio)

        // The engine is busy analyzing this unfamiliar word when a cached
        // request supersedes it. Cache playback must not wait for its stop.
        provider.submit(job("qzvbrntxkglpfwdcshjmaeiouqzvbrntxk"), voiceKey: key, settings: settings)
        Thread.sleep(forTimeInterval: 0.05)
        let submitStart = milliseconds()
        provider.submit(label, voiceKey: key, settings: settings)
        let submitMs = milliseconds() - submitStart
        let bypass = collect(provider)
        precondition(bypass.audio == live.audio && submitMs < 1000 && bypass.first < 1000)

        for i in 0..<20 { provider.submit(job("Item \(i), window."), voiceKey: key, settings: settings) }
        provider.submit(job("Final item, open."), voiceKey: key, settings: settings)
        let final = collect(provider)
        precondition(!final.audio.isEmpty)

        let long = String(repeating: "Please read the instructions carefully, before you begin. The window is open. ", count: 25)
        provider.submit(job(long), voiceKey: key, settings: settings)
        let reading = collect(provider, limit: 30)
        precondition(reading.audio.count > 22050 * 60)

        // Force the engine's no-audio timeout, then request fresh uncached speech.
        let pathological = String(repeating: "qzvbrntxkglpfwdcshjmaeiou", count: 45)
        provider.submit(job(pathological), voiceKey: key, settings: settings)
        let failed = collect(provider)
        precondition(failed.audio.allSatisfy { abs($0) < 0.001 })
        provider.submit(job("Recovered, open."), voiceKey: key, settings: settings)
        let recovered = collect(provider)
        precondition(!recovered.audio.isEmpty)
        print(String(format: "PASS real provider: first %.1f ms, cached %.1f ms, cached during cancel %.1f ms, submit %.1f ms, long reading %.1f seconds, recovered %.1f ms",
                     live.first, cached.first, bypass.first, submitMs, Double(reading.audio.count)/22050, recovered.first))
    }
}
