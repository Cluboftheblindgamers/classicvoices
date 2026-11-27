import Foundation
@testable import ClassicPortTest

/// Requires the downloaded iOS 6 and 7 Daniel Enhanced voice assets.
@main enum IOS6SpellingCheck {
    static func main() {
        let stream = VoiceEngine.shared.stream!
        let settings = SpeechSettings()
        func render(_ key: String, _ body: String, pauses: Bool = false) -> [Float] {
            let entry = VoiceCatalog.entry(forKey: key)!
            let job = SpeechJob.from(ssml: "<speak><prosody rate='250%'>\(body)</prosody></speak>",
                                     voiceKey: key, settings: settings)
            VoiceEngine.shared.speak(job, voiceKey: key,
                                     fallbackKey: VoiceCatalog.compactCounterpart(of: entry)?.key,
                                     spellingPauses: pauses)
            var pcm = [Float]()
            var packet = [Float](repeating: 0, count: 4096)
            var done: Int32 = 0
            let deadline = Date().addingTimeInterval(10)
            while done == 0 && Date() < deadline {
                let count = packet.withUnsafeMutableBufferPointer { vxs_read(stream, $0.baseAddress, $0.count, &done) }
                pcm.append(contentsOf: packet.prefix(count))
                if count == 0 && done == 0 { vxs_wait(stream, 200) }
            }
            precondition(done != 0 && String(cString: vxs_last_error(stream)).isEmpty
                         && pcm.contains { abs($0) > 0.005 }, "Daniel render failed")
            return pcm
        }
        let older = "ios6e/en-GB", newer = "ios70e/en-GB"
        func spell(_ text: String) -> String { "<say-as interpret-as='characters'>\(text)</say-as>" }
        for letters in ["en", "th", "st", "ch", "ing"] {
            let joined = render(older, spell(letters))
            let reference = render(newer, spell(letters))
            let paused = render(older, spell(letters), pauses: true)
            precondition(joined.count < paused.count, "short sequences must join: \(letters)")
            precondition(abs(joined.count - reference.count) < 2205, "joined delivery close to iOS 7: \(letters)")
        }
        let separate = spell("e") + spell("n")
        precondition(render(older, separate) == render(older, spell("en")), "adjacent SSML spelling tags join")
        let broken = spell("e") + "<break time='200ms'/>" + spell("n")
        precondition(render(older, broken).count > render(older, separate).count + 4410, "explicit break survives")
        let ordinary = "The engine selected the next item."
        precondition(render(older, ordinary) == render(older, ordinary, pauses: true), "ordinary speech unaffected")
        print("PASS iOS 6 Daniel Enhanced joined spelling, adjacent tags, explicit breaks and ordinary speech")
    }
}
