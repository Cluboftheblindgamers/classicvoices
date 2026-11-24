import Foundation
import AVFoundation
@testable import ClassicPortTest

@main struct LionNavigationCheck {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
    static func collect(_ provider: MacinTalkProvider) -> (audio: [Float], first: Double) {
        let start=now(); var first = -1.0, audio=[Float](), buffer=[Float](repeating:0,count:1024)
        while now()-start < 20_000 {
            let r=buffer.withUnsafeMutableBufferPointer { provider.read(into:$0.baseAddress!,count:$0.count,wait:0.1) }
            if r.frames>0 {
                if first<0 && buffer[..<r.frames].contains(where:{abs($0) > 0.001}) { first=now()-start }
                audio.append(contentsOf:buffer[..<r.frames])
            }
            if r.complete { precondition(first>=0 && !audio.isEmpty);return(audio,first) }
        }
        provider.cancel();preconditionFailure("Lion navigation did not finish")
    }
    static func main() throws {
        let tiger = CommandLine.arguments.contains("--tiger")
        let leopard = CommandLine.arguments.contains("--leopard")
        let snowLeopard = CommandLine.arguments.contains("--snowleopard")
        let ios10: Bool
#if CV_IOS10_ALEX
        ios10 = CommandLine.arguments.contains("--ios10-alex")
        let generation: Generation = ios10 ? .ios10Alex : tiger ? .tiger : leopard ? .leopard : snowLeopard ? .snowleopard : .lion
#else
        ios10 = false
        let generation: Generation = tiger ? .tiger : leopard ? .leopard : snowLeopard ? .snowleopard : .lion
#endif
        let key=ios10 ? "mtios10/Alex" : tiger ? "mt104/Fred" : leopard ? "mt105/Alex" : snowLeopard ? "mt106/Alex" : "mt107/Alex",provider=MacinTalkProvider()
        var settings=SpeechSettings(),profile=PantheraSettings.defaults(for:generation)
        profile.rate=394;settings.macinTalk[generation.rawValue]=profile
        let xml="<speak>Dock<break time='500ms'/>  </speak>"
        func make(_ xml:String) -> SpeechJob { SpeechJob.from(ssml:xml,voiceKey:key,settings:settings) }
        let dock=make(xml)
        precondition(dock.text=="Dock[[slnc 500]] " && dock.trailingPauseMs==0)
        provider.submit(dock,voiceKey:key,settings:settings)
        let live=collect(provider)
        precondition(live.audio.allSatisfy(\.isFinite))
        provider.submit(dock,voiceKey:key,settings:settings)
        let cached=collect(provider)
        precondition(live.audio==cached.audio && provider.metrics.cached)
        provider.submit(make("<speak>Dock</speak>"),voiceKey:key,settings:settings)
        let bare=collect(provider)
        precondition(live.audio.count>bare.audio.count+3000,"native pause reached the real engine")
        if let output = ProcessInfo.processInfo.environment["CV_PORT_TEST_OUTPUT"] {
            let destination = URL(fileURLWithPath: output).appendingPathComponent("\(generation.rawValue)-navigation-fixed.wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(live.audio.count))!
            pcm.frameLength = pcm.frameCapacity
            live.audio.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
            let file = try AVAudioFile(forWriting: destination, settings: format.settings)
            try file.write(from: pcm)
        }

        // Queue a full half-second native tail, then cancel before reading it.
        // The next uncached request must not inherit or wait for those samples.
        profile.rate=180;settings.macinTalk[generation.rawValue]=profile
        let slowDock=make(xml)
        provider.submit(slowDock,voiceKey:key,settings:settings);_=collect(provider)
        provider.submit(slowDock,voiceKey:key,settings:settings)
        var buffer=[Float](repeating:0,count:1024)
        let initial=buffer.withUnsafeMutableBufferPointer { provider.read(into:$0.baseAddress!,count:$0.count,wait:1) }
        precondition(initial.frames>0)
        let start=now();provider.cancel();let cancelMs=now()-start
        let stopped=buffer.withUnsafeMutableBufferPointer { provider.read(into:$0.baseAddress!,count:$0.count,wait:0) }
        precondition(stopped.frames==0 && stopped.complete)
        provider.submit(make("<speak>Next item after interruption.</speak>"),voiceKey:key,settings:settings)
        let next=collect(provider)
        // Expanded Snow Leopard coverage removes the old ~600 ms synthesis
        // bottleneck in the next phrase; retain the tighter recovery target.
        // The interpreted iOS prototype still has a separate baseline.
        let recoveryLimit: Double = ios10 ? 10_000 : 400
        precondition(cancelMs<100 && next.first<recoveryLimit,"queued final silence must not block a new request")
        print(String(format:"PASS %@ native final-pause PCM, cache identity and interruption: live %.1f ms, cached %.1f ms, cancel %.2f ms, next %.1f ms; frames native %d bare %d",generation.label,live.first,cached.first,cancelMs,next.first,live.audio.count,bare.audio.count))
    }
}
