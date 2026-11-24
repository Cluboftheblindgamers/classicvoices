import Foundation
import AVFoundation
import AudioToolbox

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
func wait(_ timeout: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return done()
}
var cleanup: (() -> Void)?
func fail(_ text: String) -> Never { let recover = cleanup; cleanup = nil; recover?(); fputs("FAIL: \(text)\n", stderr); exit(1) }
var loaded = false
var audioUnit: AVAudioUnit?
var loadError: Error?
let alex10 = CommandLine.arguments.contains("--ios10-alex")
let lionContext = CommandLine.arguments.contains("--lion-context")
let snowContext = CommandLine.arguments.contains("--snowleopard-context")
let isolated = alex10 || lionContext || snowContext
let identityPrefix = alex10 ? "org.pantheraspeech.classicvoices.alex10preview" : lionContext ? "org.pantheraspeech.classicvoices.lioncontext" : snowContext ? "org.pantheraspeech.classicvoices.snowpause" : "org.pantheraspeech.classicvoices.port"
let defaultGeneration = alex10 ? "ios10Alex" : lionContext ? "lion" : "snowleopard"
let desc = AudioComponentDescription(componentType: kAudioUnitType_SpeechSynthesizer,
    componentSubType: fourCC(alex10 ? "cvax" : lionContext ? "cvlp" : snowContext ? "cvsl" : "cvpt"), componentManufacturer: fourCC("PnTh"),
    componentFlags: 0, componentFlagsMask: 0)
_ = AVAudioUnitComponentManager.shared().components(matching: desc)
AVAudioUnit.instantiate(with: desc, options: []) { unit, error in
    audioUnit = unit; loadError = error; loaded = true
}
guard wait(30, until: { loaded }), let unit = audioUnit else { fail("private component: \(String(describing: loadError))") }
let channel = unit.auAudioUnit.messageChannel(for: "com.levigobin.ClassicVoices.files")
func call(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] {
    guard let result = channel.callAudioUnit?(message) else { fail("no file-channel reply") }
    guard (result["error"] as? String ?? "").isEmpty else { fail("file channel \(message["op"] ?? "?"): \(result["error"] ?? "?")") }
    return result
}
let hello = call(["op": "hello"])
guard (hello["store"] as? String)?.contains(identityPrefix) == true else { fail("unexpected store identity") }
let previous = call(["op": "read", "path": "settings.json"])["data"] as? Data
func restore() {
    if let previous { _ = call(["op": "write", "path": "settings.json", "data": previous]) }
    else { _ = call(["op": "delete", "path": "settings.json"]) }
}
cleanup = restore
let sentinel = Data("{\"macinTalkCompatibility\":true,\"macinTalk\":{\"snowleopard\":{\"inflection\":100}},\"logSpokenText\":false}".utf8)
_ = call(["op": "write", "path": "settings.json", "data": sentinel])
guard call(["op": "read", "path": "settings.json"])["data"] as? Data == sentinel else { restore(); fail("settings roundtrip") }
restore()
AVSpeechSynthesisProviderVoice.updateSpeechVoices()
let requiredVoice = alex10 ? "mtios10.Alex" : lionContext ? "mt107.Alex" : snowContext ? "mt106.Alex" : (CommandLine.arguments.contains("--vocalizer") ? "ios70.en-US" : "mt104.Fred")
_ = wait(25, until: { AVSpeechSynthesisVoice.speechVoices().contains { $0.identifier.hasPrefix(identityPrefix + ".") && $0.identifier.hasSuffix(requiredVoice) } })
let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.identifier.hasPrefix(identityPrefix + ".") }
if isolated && voices.count != 1 { fail("Alex preview must register exactly one voice") }
print("PASS private component and settings channel; system lists \(voices.count) private voices")
guard let voice = voices.first(where: { $0.identifier.hasSuffix(alex10 ? "mtios10.Alex" : lionContext ? "mt107.Alex" : "mt106.Alex") }) else { fail("private Alex not registered: \(voices.map(\.identifier))") }
func render(rate: Int, using selectedVoice: AVSpeechSynthesisVoice = voice, generation: String = defaultGeneration) -> (frames: Int, peak: Float) {
    let data = try! JSONSerialization.data(withJSONObject: ["macinTalkCompatibility": true,
        "macinTalk": [generation: ["rate": rate, "inflection": alex10 ? 140 : 100]], "logSpokenText": false])
    _ = call(["op": "write", "path": "settings.json", "data": data])
    if alex10 {
        guard call(["op":"read","path":"settings.json"])["data"] as? Data == data else { fail("rate settings write did not persist") }
        let direct = call(["op":"test","key":"mtios10/Alex","text":"Café. Settings. Button. One minute nine seconds."])
        print("DIRECT rate=\(rate): \(direct)")
    }
    let synth = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: isolated ? "Café. Settings. Button. One minute nine seconds. Test \(rate == 180 ? "one" : "two")." : "Settings. Button. One minute nine seconds.")
    if lionContext {
        guard selectedVoice.name.contains("Lion Alex Preview") else { fail("private context voice label is ambiguous") }
    }
    if snowContext {
        guard selectedVoice.name.contains("Snow Leopard Alex Preview") else { fail("private Snow Leopard voice label is ambiguous") }
    }
    utterance.voice = selectedVoice
    var complete = false, frames = 0
    var peak: Float = 0
    synth.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 { complete = true; return }
        frames += Int(pcm.frameLength)
        if let samples = pcm.floatChannelData?[0] { for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(samples[i])) } }
        else if let samples = pcm.int16ChannelData?[0] { for i in 0..<Int(pcm.frameLength) { peak = max(peak, Float(abs(Int(samples[i])))/32768) } }
    }
    guard wait(40, until: { complete }), frames > 0, peak > 0.001 else { fail("system speech complete=\(complete) frames=\(frames) peak=\(peak)") }
    return (frames, peak)
}
let normal = render(rate: 180)
let fast = render(rate: 360)
guard fast.frames < normal.frames * 3 / 4 else { fail("fixed rate settings ignored: normal=\(normal.frames) fast=\(fast.frames)") }
for (generation, suffix) in (isolated ? [] : [("tiger", "mt104.Fred"), ("leopard", "mt105.Alex"), ("lion", "mt107.Alex")]) {
    guard let selected = voices.first(where: { $0.identifier.hasSuffix(suffix) }) else { fail("missing private generation \(generation)") }
    let sample = render(rate: 180, using: selected, generation: generation)
    print("PASS system-hosted \(generation): \(sample.frames) frames, peak \(sample.peak)")
}
if CommandLine.arguments.contains("--vocalizer") {
    for suffix in ["ios3.en-US", "ios4.en-US", "ios5.en-US", "ios6.en-US", "ios70.en-US", "ios70.en-GB", "ios70.fr-FR", "ios70.zh-CN"] {
        guard let selected = voices.first(where: { $0.identifier.hasSuffix(suffix) }) else { fail("missing Vocalizer voice \(suffix)") }
        let sample = render(rate: 180, using: selected)
        print("PASS system-hosted Vocalizer \(suffix): \(sample.frames) frames, peak \(sample.peak)")
    }
}
restore(); cleanup = nil
print("PASS system-hosted private Alex and live settings: 180 WPM \(normal.frames) frames, 360 WPM \(fast.frames) frames; original settings restored")
