import Foundation

/// Legacy Panthera storage helpers are retained for importing its exports.
/// The active Classic Voices settings travel in settings.json through VoiceStore.
public enum AppGroup {
    public static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
}

enum MacinTalkCompatibility {
    static func generation(for key: String) -> Generation? {
        switch key.split(separator: "/").first {
        case "mt104": return .tiger
        case "mt105": return .leopard
        case "mt106": return .snowleopard
        case "mt107": return .lion
        default: return nil
        }
    }

    /// Retain Panthera's stable identifiers inside imported pronunciation scopes.
    /// This does not rename any Classic Voices system voice.
    static func pronunciationID(for key: String) -> String? {
        guard let generation = generation(for: key), let name = key.split(separator: "/").last else { return nil }
        return "com.pantheraspeech.\(generation.rawValue).\(name.lowercased())"
    }

    static func prepare(_ text: String, voiceKey: String, settings: SpeechSettings,
                        spelling: Bool = false, internalMarks: Bool = false) -> String {
        guard settings.macinTalkCompatibility, let generation = generation(for: voiceKey) else { return text }
        let profile = settings.macinTalkSettings(generation)
        let prepared: String
        if spelling {
            prepared = SpeechText.prepare(internalMarks ? text : SSMLRequest.removingInternalMarks(text),
                                          settings: profile, generation: generation, spelling: true)
        } else {
            prepared = Pronunciations.prepare(text, entries: settings.macinTalkPronunciations,
                                      settings: profile, generation: generation,
                                      voiceID: pronunciationID(for: voiceKey), internalMarks: internalMarks)
        }
        // Internal markers must reach Pronunciations before the MacRoman fold.
        let style: Int32 = profile.numbers == .words ? 2 : profile.numbers == .fix ? 1 : 0
        let numbered: String
        if style != 0, let rewritten = mte_rewrite_numbers(prepared, style) {
            numbered = String(cString: rewritten); free(rewritten)
        } else { numbered = prepared }
        let bytes = MacRoman.encode(numbered).dropLast().map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? numbered
    }

    /// The normal MacinTalk request path uses Panthera's traced SSML handling.
    /// Classic's bookmark/IPA parser remains responsible for those richer requests.
    static func job(ssml: String, voiceKey: String, settings: SpeechSettings,
                    dictionary: CommunityDictionary?, phonemes: ((String, Bool) -> String?)?) -> SpeechJob? {
        guard settings.macinTalkCompatibility, let generation = generation(for: voiceKey) else { return nil }
        let profile = settings.macinTalkSettings(generation)
        let request = SSMLRequest(ssml: ssml)
        guard !request.requiresLegacyParser else { return nil }
        let wpm = profile.wpm(requestMultiplier: request.rateMultiplier)
        let pieces = request.pieces(natural: profile.naturalPauses, wpm: wpm,
                                    clauses: profile.quickInterrupt, macVoiceOver: true,
                                    macPauses: profile.macPauses, style: .of(generation))
        var job = SpeechJob()
        let multiplier = request.rateMultiplier.isFinite ? min(100, max(0.01, request.rateMultiplier)) : 1
        job.rate = Int((multiplier * 100).rounded())
        job.macinTalkWPM = wpm
        job.pitch = percentPitch(request.pitchTenths)
        job.macinTalkPitchTenths = request.pitchTenths
        job.volume = 100
        job.macinTalkGain = request.gain
        var text = ""
        var pitch = request.pitchTenths
        for (index, piece) in pieces.enumerated() {
            let askedPitch = piece.pitchTenths ?? request.pitchTenths
            if askedPitch != pitch {
                text += " \u{1b}\\pitchtenths=\(askedPitch)\\ "
                pitch = askedPitch
            }
            let prepared = prepare(piece.text, voiceKey: voiceKey, settings: settings, internalMarks: true)
            text += applying(dictionary, to: prepared, phonemes: phonemes)
            if index < pieces.count - 1 {
                if piece.pauseAfterMs > 0 { text += " \u{1b}\\pause=\(piece.pauseAfterMs)\\ " }
                text += " \u{1b}\\eos=1\\ "
            } // Panthera omits a final trailing break, keeping navigation responsive.
        }
        job.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.pauseOnlyMs > 0 { job.trailingPauseMs = request.pauseOnlyMs }
        return job
    }

    private static func percentPitch(_ tenths: Int) -> Int {
        min(200, max(50, Int((100 * pow(2, Double(tenths) / 120)).rounded())))
    }

    /// Custom Classic dictionaries still work. Never run dictionary patterns
    /// over generated MacinTalk commands, phonemes, or literal spelling spans.
    private static func applying(_ dictionary: CommunityDictionary?, to text: String,
                                 phonemes: ((String, Bool) -> String?)?) -> String {
        guard let dictionary else { return text }
        let command = try! NSRegularExpression(pattern: #"\[\[[^\]]*\]\]"#)
        let ns = text as NSString
        var out = "", at = 0, protected = false, spelling = false
        func plain(_ s: String) -> String {
            protected || spelling ? s : dictionary.speechText(s, rules: nil, phonemes: phonemes)
        }
        for match in command.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += plain(ns.substring(with: NSRange(location: at, length: match.range.location - at)))
            let token = ns.substring(with: match.range)
            out += token
            let upper = token.uppercased()
            if upper.contains("INPT PHON") { protected = true }
            if upper.contains("INPT TEXT") { protected = false }
            if upper.contains("CHAR LTRL") { spelling = true }
            if upper.contains("CHAR NORM") { spelling = false }
            at = match.range.location + match.range.length
        }
        return out + plain(ns.substring(from: at))
    }
}
