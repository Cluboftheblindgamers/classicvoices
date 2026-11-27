import AVFoundation
import os

/// System speech-synthesis provider backed by the original iOS 6 Vocalizer engine.
public final class ClassicVoicesAudioUnit: AVSpeechSynthesisProviderAudioUnit {
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050,
                                       channels: 1, interleaved: false)!
    private var outputBus: AUAudioUnitBus!
    private var busses: AUAudioUnitBusArray!
    private let macinTalk = MacinTalkProvider()
    private struct RenderRequest {
        var token: UInt64 = 0
        var macinTalk = false
        var pcmToken: UInt64? = nil
        var request: AVSpeechSynthesisProviderRequest? = nil
        var names: [String] = []
    }
    private let current = OSAllocatedUnfairLock(initialState: RenderRequest())
    private let requestLock = NSLock()

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        outputBus = try AUAudioUnitBus(format: format)
        busses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        VoiceCatalog.adoptLegacy()
        DispatchQueue.global(qos: .utility).async { VoiceCatalog.unprotectVoices() }
        // Warm up the most recently used voice so the first utterance is fast,
        // with the pronunciation pack it will speak with.
        let last = UserDefaults.standard.string(forKey: "lastVoiceKey") ?? "ios6/en-US"
        let lastEntry = VoiceCatalog.entry(forKey: last)
        let settings = SpeechSettings.current
        if last.hasPrefix("mt") { MacinTalkProvider.preload(last, settings: settings) }
        else {
            VoiceEngine.shared.preload(last, rulesPack: PronunciationRules.newerPack(
                forVoiceKey: last, identifier: lastEntry?.identifier ?? "", language: lastEntry?.language ?? "",
                settings: settings))
        }
        // and its rules: reading a newer pack's thousands of them takes tens of milliseconds
        DispatchQueue.global(qos: .userInitiated).async {
            _ = PronunciationRules.rules(forVoiceKey: last, identifier: lastEntry?.identifier ?? "",
                                         language: lastEntry?.language ?? "", settings: settings)
        }
        log.notice("CLASSICVOICES audio unit created; root=\(VoiceCatalog.root?.path ?? "nil", privacy: .public) voices=\(VoiceCatalog.entries.count)")
    }
    deinit { VoiceEngine.speechOwner.cancel(current.withLock { $0.token }); macinTalk.cancel() }

    public override var outputBusses: AUAudioUnitBusArray { busses }

    private let fileChannel = FileChannel()
    public override func messageChannel(for channelName: String) -> any AUMessageChannel {
        fileChannel
    }

    public override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            VoiceCatalog.invalidateEnhanced()  // the app asked the system to update the list
            let v = VoiceCatalog.providerVoices
            log.notice("CLASSICVOICES speechVoices requested -> \(v.count) voices")
            return v
        }
        set {}
    }

    /// Diagnostic samples are small and protected independently of the audio stream.
    private struct TraceState {
        var start: UInt64 = 0
        var count = 0
        var renders = [(UInt64, Int32, Int32)](repeating: (0, 0, 0), count: 8)
    }
    private let trace = OSAllocatedUnfairLock(initialState: TraceState())

    /// Logs how the previous request's first renders went (given its start
    /// time and render count, taken before the new request reset them).
    private func dumpRenderLog(start: UInt64, count n: Int, renders: [(UInt64, Int32, Int32)]) {
        guard n > 0, start > 0 else { return }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        // A render can be logged between the count reset and the new start time, so never subtract past zero.
        let ms = { (t: UInt64) in Double(t > start ? t - start : 0) * Double(tb.numer) / Double(tb.denom) / 1e6 }
        let parts = renders.map { t, asked, given in String(format: "+%.0fms ask=%d got=%d", ms(t), asked, given) }
        log.notice("CLASSICVOICES renders: \(parts.joined(separator: " | "), privacy: .public)")
    }

    public override func synthesizeSpeechRequest(_ request: AVSpeechSynthesisProviderRequest) {
        requestLock.lock(); defer { requestLock.unlock() }
        let previous = trace.withLock { state -> (UInt64, Int, [(UInt64, Int32, Int32)]) in
            let result = (state.start, state.count, Array(state.renders.prefix(state.count)))
            state.count = 0
            state.start = mach_absolute_time()
            return result
        }
        let entry = VoiceCatalog.entry(forIdentifier: request.voice.identifier)
        if entry == nil {
            log.error("CLASSICVOICES voice lookup failed: asked=\(request.voice.identifier, privacy: .public) prefix=\(BuildIdentity.voicePrefix, privacy: .public) catalog=\(VoiceCatalog.entries.map(\.identifier).joined(separator: ","), privacy: .public)")
        }
        let key = entry?.key ?? "ios6/" + (request.voice.primaryLanguages.first ?? "en-US")
        let settings = SpeechSettings.current
        let language = entry?.language ?? request.voice.primaryLanguages.first ?? ""
        let rules = PronunciationRules.rules(forVoiceKey: key, identifier: entry?.identifier ?? "", language: language,
                                             settings: settings)
        // the person's own dictionary entries always, the community's when turned on (none while the editor is open)
        let dictionary = CommunityDictionary.forVoice(key: key, language: language, community: settings.communityDictionaries)
        let job = SpeechJob.from(ssml: request.ssmlRepresentation, rules: rules, dictionary: dictionary,
                                 exactPitch: key.hasPrefix("mt"), phonemes: { ipa, joined in
            VoiceEngine.phonemeText(key: key, language: language, ipa: ipa, joined: joined)
        }, voiceKey: key, settings: settings)
        let fallback = entry.flatMap { settings.pitchFallbackEnabled($0.identifier) ? VoiceCatalog.compactCounterpart(of: $0)?.key : nil }
        let pack = PronunciationRules.newerPack(forVoiceKey: key, identifier: entry?.identifier ?? "", language: language,
                                                settings: settings)
        let useMacinTalk = key.hasPrefix("mt")
        let owner = VoiceEngine.speechOwner
        let publish: (UInt64) -> Void = { token in
            self.current.withLock { $0 = RenderRequest(token: token, macinTalk: useMacinTalk,
                                                       request: request, names: job.markNames) }
        }
        if useMacinTalk {
            owner.begin(publish: publish, onSuperseded: { [macinTalk] in macinTalk.cancel() }) {
                let token = macinTalk.submit(job, voiceKey: key, settings: settings)
                current.withLock { $0.pcmToken = token }
            }
        } else {
            let engine = VoiceEngine.shared
            owner.begin(publish: publish, onSuperseded: { engine.cancel() }) {
                macinTalk.supersedeOtherRequests()
                macinTalk.cancel()
                engine.speak(job, voiceKey: key, fallbackKey: fallback, rulesPack: pack,
                             resetCommands: settings.resetCommandsEnabled(entry?.identifier ?? ""),
                             twentyFourHour: settings.twentyFourHour, modernRate: settings.modernRate,
                             steadyPauses: settings.steadyPauses, spellingPauses: settings.spellingPauses,
                             spellLowercase: settings.spellLowercase, settings: settings)
            }
        }
        dumpRenderLog(start: previous.0, count: previous.1, renders: previous.2)
        log.notice("CLASSICVOICES request \(key, privacy: .public) rate=\(job.rate) wpm=\(job.macinTalkWPM ?? 0) pitch=\(job.pitch) pause=\(job.trailingPauseMs)")
        if settings.logSpokenText {
            log.notice("CLASSICVOICES spoken text=[\(job.text.replacingOccurrences(of: "\u{1b}", with: "<ESC>"), privacy: .public)] ssml=\(request.ssmlRepresentation, privacy: .public)")
        }
        if UserDefaults.standard.string(forKey: "lastVoiceKey") != key {
            UserDefaults.standard.set(key, forKey: "lastVoiceKey")
        }
    }

    public override func cancelSpeechRequest() {
        requestLock.lock(); defer { requestLock.unlock() }
        let token = current.withLock { state -> UInt64 in
            defer { state = RenderRequest() }
            return state.token
        }
        VoiceEngine.speechOwner.cancel(token)
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        let macinTalk = self.macinTalk, current = self.current
        let trace = self.trace
        let owner = VoiceEngine.speechOwner
        return { [weak self] actionFlags, _, frameCount, _, outputData, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let raw = buffers[0].mData else { return noErr }
            let out = raw.assumingMemoryBound(to: Float.self)
            let frames = Int(frameCount)
            var done: Int32 = 1
            var n = 0
            // A render is tied to one immutable request; it cannot consume a
            // newer request's samples or metadata when the unit is reused.
            let snapshot = current.withLock { $0 }
            let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
            var markerValues: [(Int, Int)] = []
            if snapshot.macinTalk {
                if let pcmToken = snapshot.pcmToken,
                   case .granted = owner.access(snapshot.token, { () }) {
                    let result = macinTalk.read(into: out, count: frames, token: pcmToken)
                    n = result.frames; done = result.complete ? 1 : 0
                    markerValues = macinTalk.takeMarkers(token: pcmToken).map { ($0.id, $0.frame) }
                } else if case .changing = owner.access(snapshot.token, { () }) {
                    done = 0
                }
            } else if snapshot.token != 0, let stream = VoiceEngine.shared.stream {
                while true {
                    var d: Int32 = 0
                    switch owner.access(snapshot.token, { vxs_read(stream, out + n, frames - n, &d) }) {
                    case .granted(let got): n += got; done = d
                    case .changing: done = 0
                    case .superseded: done = 1
                    }
                    if n == frames || done != 0 || DispatchTime.now().uptimeNanoseconds > deadline { break }
                    usleep(500)
                }
                var got = [VxsMark](repeating: VxsMark(), count: 8)
                if case .granted(let read) = owner.access(snapshot.token, {
                    got.withUnsafeMutableBufferPointer { vxs_read_marks(stream, $0.baseAddress, 8) }
                }) {
                    markerValues = got[..<read].map { (Int($0.id), Int($0.frame)) }
                }
            }
            let sameRequest = current.withLock { $0.token == snapshot.token }
            switch owner.access(snapshot.token, { () }) {
            case .granted where sameRequest:
                if let request = snapshot.request, let report = self?.speechSynthesisOutputMetadataBlock {
                    let markers = markerValues.compactMap { id, frame in
                        id >= 0 && id < snapshot.names.count
                            ? AVSpeechSynthesisMarker(bookmarkName: snapshot.names[id], atByteSampleOffset: frame * 4) : nil
                    }
                    if !markers.isEmpty { report(markers, request) }
                }
            case .changing:
                n = 0; done = 0
            default:
                n = 0; done = sameRequest ? 1 : 0
            }
            let renderedFrames = n
            trace.withLock { state in
                if state.count < state.renders.count {
                    state.renders[state.count] = (mach_absolute_time(), Int32(frames), Int32(renderedFrames))
                    state.count += 1
                }
            }
            if n < frames { (out + n).update(repeating: 0, count: frames - n) }
            buffers[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            if done != 0 && n == 0 {
                actionFlags.pointee = .offlineUnitRenderAction_Complete
            }
            return noErr
        }
    }
}
