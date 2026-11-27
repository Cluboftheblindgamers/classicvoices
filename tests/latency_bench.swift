import Foundation
@testable import ClassicPortTest

/// Optional engine-level latency benchmark (not part of check_panthera_port.py).
/// Direct stream pulls on this Mac: not VoiceOver or device measurements.
///
/// Build against the module check_panthera_port.py makes, then run:
///   swiftc -O -module-cache-path build/swift-cache -I core -import-objc-header ios/Shared/Bridging.h \
///     -DCV_PUBLIC -DCV_PORT_TEST -parse-as-library -I <build-dir> tests/latency_bench.swift \
///     -L <build-dir> -lClassicPortTest -Xlinker -rpath -Xlinker <build-dir> -o <build-dir>/latency_bench
///   CV_PORT_ROOT=<voices> CV_PORT_NATIVE_DIR=<native .so folder> <build-dir>/latency_bench [runs] key...
/// Per key and run: a fresh stream; cold and warm first audio of a short
/// phrase (VoiceOver-like rate 190%), the stop time of a long reading
/// cancelled once it is audible, and first audio of the next phrase.
/// Then iOS 6 Enhanced spelling at 250% (Build 29 joining), boost off and on.
@main enum LatencyBench {
    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    static func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }

    /// First audible sample after `vxs_start`, optionally reading to the end; (first ms, total ms, audio ms).
    static func pull(_ stream: OpaquePointer, drain: Bool, start: Double) -> (Double, Double, Double) {
        var first = -1.0, done: Int32 = 0, frames = 0
        var samples = [Float](repeating: 0, count: 512)
        while now() - start < 20_000 {
            let n = samples.withUnsafeMutableBufferPointer { vxs_read(stream, $0.baseAddress, $0.count, &done) }
            frames += n
            if first < 0, samples.prefix(n).contains(where: { abs($0) > 0.005 }) {
                first = now() - start
                if !drain { break }
            }
            if done != 0 && n == 0 { break }
            if n == 0 { vxs_wait(stream, 2000) }
        }
        return (first, now() - start, Double(frames) * 1000 / 22050)
    }

    static func main() {
        let env = ProcessInfo.processInfo.environment
        guard let root = env["CV_PORT_ROOT"] else { print("set CV_PORT_ROOT"); return }
        _ = VoiceEngine.shared  // loads the native code from CV_PORT_NATIVE_DIR, as the extension does
        var args = Array(CommandLine.arguments.dropFirst())
        let runs = args.first.flatMap(Int.init) ?? 7
        if Int(args.first ?? "") != nil { args.removeFirst() }
        let keys = args.isEmpty ? ["ios6e/en-GB", "ios70e/en-GB", "ios6/en-GB", "mt104/Fred", "mt105/Alex", "mt106/Alex", "mt107/Alex"] : args
        let short = "Settings, button.", long = String(repeating: "Showing recent messages, applications, and selected files. Open the window or continue to the next item. ", count: 40)
        print("key | runs | cold first ms | warm first ms | cancel ms (median/max) | next first ms | footprint MB")
        for key in keys {
            var cold: [Double] = [], warm: [Double] = [], cancel: [Double] = [], next: [Double] = []
            for _ in 0..<runs {
                guard let stream = vxs_create(root) else { print("\(key): no stream"); return }
                vxs_set_asset_root(stream, root)
                func say(_ text: String, drain: Bool = true) -> Double {
                    let start = now()
                    vxs_start(stream, key, text, 190, 100, 80, 0)
                    return pull(stream, drain: drain, start: start).0
                }
                cold.append(say(short)); warm.append(say(short))
                _ = say(long, drain: false)
                let c0 = now(); vxs_cancel(stream); cancel.append(now() - c0)
                next.append(say(short))
                vxs_destroy(stream)
            }
            print(String(format: "%@ | %d | %.1f | %.1f | %.2f/%.2f | %.1f | %.0f", key, runs, median(cold), median(warm),
                         median(cancel), cancel.max() ?? .nan, median(next), footprintMB()))
        }
        // Build 29: iOS 6 Enhanced spelled-letter runs at 250%, through the
        // same request path as the speech extension (SpeechJob + VoiceEngine).
        guard VoiceCatalog.entry(forKey: "ios6e/en-GB") != nil, let stream = VoiceEngine.shared.stream else { return }
        print("spelling (ios6e/en-GB, 250%) | boost | audio ms joined | audio ms with spelling pauses | first ms joined")
        for boost in [false, true] {
            var settings = SpeechSettings(); settings.vocalizerRateBoost = boost
            for letters in ["en", "th", "st", "ch", "ing", "EN"] {
                func render(pauses: Bool) -> (Double, Double) {
                    let entry = VoiceCatalog.entry(forKey: "ios6e/en-GB")!
                    let job = SpeechJob.from(ssml: "<speak><prosody rate='250%'><say-as interpret-as='characters'>\(letters)</say-as></prosody></speak>",
                                             voiceKey: "ios6e/en-GB", settings: settings)
                    let start = now()
                    VoiceEngine.shared.speak(job, voiceKey: "ios6e/en-GB", fallbackKey: VoiceCatalog.compactCounterpart(of: entry)?.key,
                                             spellingPauses: pauses, settings: settings)
                    let r = pull(stream, drain: true, start: start)
                    return (r.2, r.0)
                }
                _ = render(pauses: false)  // phonemes cached, voice loaded
                let joined = render(pauses: false), paused = render(pauses: true)
                print(String(format: "%@ | %@ | %.0f | %.0f | %.1f", letters, boost ? "on" : "off", joined.0, paused.0, joined.1))
            }
        }
    }
}
