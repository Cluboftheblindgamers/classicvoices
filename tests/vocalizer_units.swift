import AVFoundation
@testable import ClassicUnitTest

/// Several ClassicVoicesAudioUnit instances in one process share the one
/// Vocalizer stream, as they do in the extension when the system keeps an old
/// unit (a new unit after an unlock, an app-hosted unit beside VoiceOver's).
/// A superseded unit's late cancel or render must not silence, steal from or
/// take the bookmarks of the request another unit is speaking.
/// Needs CV_PORT_ROOT with the iOS 6 compact voices (ios6/voiced, TTSResources/en-GB).
@main struct VocalizerUnits {
    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    static func makeUnit() -> ClassicVoicesAudioUnit {
        let description = AudioComponentDescription(componentType: fourCC("ausp"), componentSubType: fourCC("cvox"),
                                                    componentManufacturer: fourCC("ClVo"), componentFlags: 0,
                                                    componentFlagsMask: 0)
        do { return try ClassicVoicesAudioUnit(componentDescription: description, options: []) }
        catch { fatalError("audio unit: \(error)") }
    }

    /// Pulls a unit's render block the way the speech service does.
    final class Puller {
        let unit: ClassicVoicesAudioUnit
        let block: AUInternalRenderBlock
        private(set) var markers: [String] = []
        init(_ unit: ClassicVoicesAudioUnit) {
            self.unit = unit
            block = unit.internalRenderBlock
            unit.speechSynthesisOutputMetadataBlock = { [weak self] found, _ in
                self?.markers += found.compactMap(\.bookmarkName)
            }
        }
        func pull(_ frames: Int = 512) -> (samples: [Float], complete: Bool) {
            var samples = [Float](repeating: 0, count: frames)
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                return block(&flags, &timestamp, AUAudioFrameCount(frames), 0, list.unsafeMutablePointer, nil, nil)
            }
            precondition(status == noErr)
            return (samples, flags.contains(.offlineUnitRenderAction_Complete))
        }
        /// Everything until the unit says the request is complete.
        func collect(limit: Double = 15) -> [Float] {
            var out: [Float] = []
            let start = Date()
            while Date().timeIntervalSince(start) < limit {
                let (samples, complete) = pull()
                out += samples
                if complete { return out }
            }
            fatalError("request did not complete within \(limit) s")
        }
    }

    static func request(_ ssml: String, _ voice: VoiceCatalog.Entry) -> AVSpeechSynthesisProviderRequest {
        let v = AVSpeechSynthesisProviderVoice(name: voice.displayName, identifier: voice.identifier,
                                               primaryLanguages: [voice.language], supportedLanguages: [voice.language])
        return AVSpeechSynthesisProviderRequest(ssmlRepresentation: ssml, voice: v)
    }

    /// Render padding is exact zeros wherever a buffer was not filled, which
    /// depends on timing; compare what the voice said.
    static func heard(_ samples: [Float]) -> [Float] { samples.filter { $0 != 0 } }

    /// The audio unit remembers its last voice in the process's defaults. The
    /// runner passes `-lastVoiceKey ios6/en-GB` (argument domain), so nothing
    /// is normally saved; if a voice key was saved anyway, remove it again.
    static func forgetLastVoice() {
        let name = ProcessInfo.processInfo.processName
        if let saved = UserDefaults.standard.persistentDomain(forName: name), !saved.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    static func require(_ condition: Bool, _ what: String) {
        if !condition { print("FAIL \(what)"); forgetLastVoice(); exit(1) }
    }

    static func main() {
        defer { forgetLastVoice() }
        guard let voice = VoiceCatalog.entries.first(where: { $0.key == "ios6/en-GB" })
                ?? VoiceCatalog.entries.first(where: { $0.build == "ios6" && !$0.enhanced && $0.macDir == nil }) else {
            print("SKIP no iOS 6 compact voice under CV_PORT_ROOT"); return
        }
        let long = "<speak>" + String(repeating: "This first request keeps the engine busy for a while. ", count: 8) + "</speak>"
        let second = "<speak>Second unit <mark name=\"one\"/>speaking <mark name=\"two\"/>now.</speak>"

        // The second request alone: what it should sound like, and its bookmarks.
        let reference = Puller(makeUnit())
        reference.unit.synthesizeSpeechRequest(request(second, voice))
        let expected = heard(reference.collect())
        require(!expected.isEmpty, "reference request produced audio")
        require(reference.markers == ["one", "two"], "reference bookmarks \(reference.markers)")

        // 1. A unit the system no longer uses is cancelled after another unit started speaking.
        do {
            let old = Puller(makeUnit()), current = Puller(makeUnit())
            old.unit.synthesizeSpeechRequest(request(long, voice))
            for _ in 0..<3 { _ = old.pull() }
            current.unit.synthesizeSpeechRequest(request(second, voice))
            old.unit.cancelSpeechRequest()
            let got = heard(current.collect())
            require(got == expected, "late cancel of a superseded unit left the current request intact (\(got.count) of \(expected.count) samples)")
            require(current.markers == ["one", "two"], "current unit kept its bookmarks after a late cancel (\(current.markers))")
        }

        // 2. The superseded unit is pulled once more after the other unit started.
        do {
            let old = Puller(makeUnit()), current = Puller(makeUnit())
            old.unit.synthesizeSpeechRequest(request(long, voice))
            for _ in 0..<2 { _ = old.pull() }
            current.unit.synthesizeSpeechRequest(request(second, voice))
            let late = old.pull()
            require(heard(late.samples).isEmpty && late.complete, "superseded unit's render takes no audio and completes")
            let got = heard(current.collect())
            require(got == expected, "current request heard in full after a superseded render (\(got.count) of \(expected.count) samples)")
            require(current.markers == ["one", "two"], "current unit kept its bookmarks after a superseded render (\(current.markers))")
            require(old.markers.isEmpty, "superseded unit reported no bookmarks of another request (\(old.markers))")
        }

        // 3. One unit, as before: its own cancel stops it, and it speaks again afterwards.
        do {
            let unit = Puller(makeUnit())
            unit.unit.synthesizeSpeechRequest(request(long, voice))
            _ = unit.pull()
            unit.unit.cancelSpeechRequest()
            let after = unit.pull()
            require(heard(after.samples).isEmpty && after.complete, "own cancel ends the request")
            unit.unit.synthesizeSpeechRequest(request(second, voice))
            require(heard(unit.collect()) == expected, "unit speaks again after its own cancel")
            // and a request superseding its own previous one on the same unit
            unit.unit.synthesizeSpeechRequest(request(long, voice))
            _ = unit.pull()
            unit.unit.synthesizeSpeechRequest(request(second, voice))
            require(heard(unit.collect()) == expected, "same-unit supersession speaks the new request")
        }
        if let mt = VoiceCatalog.entries.first(where: { $0.key == "mt104/Fred" }) {
            let old = Puller(makeUnit()), next = Puller(makeUnit())
            old.unit.synthesizeSpeechRequest(request(long, voice))
            _ = old.pull()
            next.unit.synthesizeSpeechRequest(request(second, mt))
            let staleVocalizer = old.pull()
            require(heard(staleVocalizer.samples).isEmpty && staleVocalizer.complete, "MacinTalk supersedes Vocalizer")
            require(!heard(next.collect()).isEmpty, "MacinTalk after Vocalizer")
            old.unit.synthesizeSpeechRequest(request(long, mt))
            _ = old.pull()
            next.unit.synthesizeSpeechRequest(request(second, voice))
            let staleMacinTalk = old.pull()
            require(heard(staleMacinTalk.samples).isEmpty && staleMacinTalk.complete, "Vocalizer supersedes MacinTalk")
            old.unit.cancelSpeechRequest()
            require(heard(next.collect()) == expected, "late MacinTalk cancel leaves Vocalizer intact")
        }
        print("PASS Vocalizer units: superseded units' late cancel and render leave the current request, its audio and bookmarks intact; own cancel and same-unit supersession unchanged")
    }
}
