import Foundation
@testable import ClassicPortTest

@main struct SequoiaInflectionCheck {
    static func render(_ settings: SpeechSettings) -> [Float] {
        let provider = MacinTalkProvider(), key = "mt107/Alex-sequoia"
        let job = SpeechJob.from(ssml: "<speak>Safari. Dock<break time='500ms'/></speak>", voiceKey: key, settings: settings)
        provider.submit(job, voiceKey: key, settings: settings)
        var audio = [Float](), buffer = [Float](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let result = buffer.withUnsafeMutableBufferPointer { provider.read(into: $0.baseAddress!, count: $0.count, wait: 0.1) }
            audio.append(contentsOf: buffer[..<result.frames])
            if result.complete {
                precondition(!audio.isEmpty && audio.allSatisfy(\.isFinite) && audio.contains { abs($0) > 0.001 })
                return audio
            }
        }
        provider.cancel(); preconditionFailure("Sequoia Alex render timed out")
    }
    static func main() {
        var defaults = SpeechSettings()
        var lion = PantheraSettings.defaults(for: .lion); lion.rate = 180
        defaults.macinTalk[Generation.lion.rawValue] = lion
        let normal = render(defaults)
        var explicit = defaults
        explicit.macinTalkInflectionOverride["mt107/Alex-sequoia"] = 140
        precondition(normal == render(explicit), "Default newer Alex must reach the engine as pmod 140")
        explicit.macinTalkInflectionOverride["mt107/Alex-sequoia"] = 100
        precondition(normal != render(explicit), "Sequoia inflection control must change actual engine audio")
        precondition(defaults.macinTalkSettings(.lion, voiceKey: "mt107/Alex").inflection == 100)
        print("PASS real Sequoia engine: default matches explicit pmod 140; pmod 100 changes PCM; original Lion default remains 100")
    }
}
