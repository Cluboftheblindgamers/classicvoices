// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import AVFAudio
import Foundation

/// What a system speech request asks for, read out of its SSML.
///
/// iOS hands a speech extension SSML rather than text plus parameters:
/// VoiceOver's rate and pitch arrive as `<prosody>` attributes. Exactly which
/// attributes and units VoiceOver sends is worth confirming on a device --
/// the extension logs every request's SSML in debug builds for that -- so the
/// parsing below accepts all the forms the SSML 1.1 spec allows.
public struct SSMLRequest: Equatable, Sendable {
    /// Plain text, markup removed.
    public var text: String
    /// The caller's final break, before legacy navigation trimming.
    public var requestedTrailingPauseMs: Int = 0
    /// 1.0 is the normal rate; 2.0 is twice as fast.
    public var rateMultiplier: Double
    /// Tenths of a semitone from the voice's own pitch, the unit
    /// panthera_set_pitch takes; clamped to an octave either way.
    public var pitchTenths: Int
    /// The text split at the request's `<break>`s, each piece with the pause
    /// that follows it.  VoiceOver separates the parts of what it announces
    /// ("Claude <break 250ms/> window <break 60ms/> ...") this way; speaking
    /// the pieces one after another keeps those pauses, and the first piece
    /// is audible as soon as it alone is rendered rather than after the
    /// whole announcement.
    public var segments: [Segment]
    /// A request that is only a pause (VoiceOver sends `<break time=
    /// "680ms"/>` on its own): how long, so it can be answered with that much
    /// silence, as Apple's voices do, rather than with no audio at all.
    public var pauseOnlyMs = 0
    /// Classic's parser retains IPA, bookmarks, languages and nested rate/volume.
    public var requiresLegacyParser = false
    /// VoiceOver's speech volume, as a factor on the samples: it sends
    /// `<prosody volume="-1.9382001dB">` (Oct 23 log), which Apple's voices
    /// apply and this extension ignored, so Panthera played louder than
    /// VoiceOver asked.  1 when the request names no volume.
    public var gain: Float = 1

    public struct Segment: Equatable, Sendable {
        public var text: String
        public var pauseAfterMs: Int
        /// A pitch of its own, in the request's tenths of a semitone from the
        /// voice's pitch, when a `<prosody pitch>` inside the request changes
        /// it for this part: VoiceOver raises the pitch of a capital letter
        /// and lowers it for deleted text this way, and the pitch rotor too.
        /// nil: the request's pitch.
        public var pitchTenths: Int?
        public init(text: String, pauseAfterMs: Int = 0, pitchTenths: Int? = nil) {
            self.text = text; self.pauseAfterMs = pauseAfterMs; self.pitchTenths = pitchTenths
        }
    }

    public init(text: String, rateMultiplier: Double = 1, pitchTenths: Int = 0, segments: [Segment]? = nil) {
        self.text = Self.removingInternalMarks(text)
        self.rateMultiplier = rateMultiplier
        self.pitchTenths = pitchTenths
        self.segments = (segments ?? [Segment(text: text)]).map {
            var segment = $0
            segment.text = Self.removingInternalMarks(segment.text)
            return segment
        }
    }

    public init(ssml: String) {
        let prosody = ProsodyReader(ssml)
        // Pieces only when the markup parsed; otherwise the whole text, once.
        let pieces = prosody.parsed ? prosody.segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.pauseAfterMs > 0 } : []
        let trailingPause = Self.merged(pieces, preserveTrailingPause: true).last?.pauseAfterMs ?? 0
        let segments = pieces.isEmpty ? nil : Self.merged(pieces)
        // The plain text is only spoken when the markup gave no pieces, so the
        // system's own SSML reader -- a second parse of the same markup, on
        // every request -- runs only then.
        let text = segments.map { $0.map(\.text).joined(separator: " ") }
            ?? AVSpeechUtterance(ssmlRepresentation: ssml)?.speechString ?? Self.stripTags(ssml)
        self.init(text: text,
                  rateMultiplier: prosody.rate.flatMap(Self.rate(_:)) ?? 1,
                  pitchTenths: prosody.pitch.flatMap(Self.pitch(_:)) ?? 0,
                  segments: nil)
        requestedTrailingPauseMs = trailingPause
        if let segments { self.segments = segments }
        requiresLegacyParser = !prosody.parsed || prosody.requiresLegacyParser
        gain = prosody.volume.flatMap(Self.gain(_:)) ?? 1
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pauseOnlyMs = pieces.reduce(0) { Self.addingPauses($0, $1.pauseAfterMs) }
        }
    }

    /// What the engine is actually given: VoiceOver's parts joined into one
    /// utterance where it paused only briefly (`natural`), and that is all --
    /// unless quick interruptions are on (`clauses`), when long pieces are
    /// cut at their sentences and commas so a swipe can stop them sooner.
    ///
    /// Oct 25: cutting between sentences by default lost Alex's breaths.
    /// Within one utterance the engine ends a sentence with its own pause and,
    /// for Alex, a recorded breath (Snow Leopard Alex, two sentences: ~380 ms
    /// of breath between them); two utterances got a fixed silence instead,
    /// and every period sounded clipped.  So the whole announcement is one
    /// utterance, as `say` and the Mac give it, and only quick interruptions
    /// trade that for responsiveness.
    /// How VoiceOver on one Mac OS X spoke spelled characters, capitals and
    /// pauses, traced in VMs (Nov 5).  Snow Leopard: a capital "[[pbas +9]]",
    /// every letter and digit closed by "[[slnc 60]] ", a short pause as a
    /// silence before the comma.  Leopard (10.5.7, its VoiceOver is
    /// screenreaderd): "[[pbas +6]]", no closing silence, a short pause a
    /// comma alone ("\"TextEdit\" , running"); its deletions untraced, so
    /// Snow Leopard's.  Lion (10.7.5): "[[pbas +9]]", a deletion
    /// "[[pbas -6]]", no closing silence, and no pause at all between an item
    /// and its role ("\"Downloads\" folder").  Tiger takes Leopard's (no
    /// DTrace on 10.4).
    public struct VoiceOverStyle: Equatable, Sendable {
        public var capitalTenths: Int
        public var deletionTenths: Int
        public var closingSilence: Bool
        public var pauseSilence: Bool
        /// A short pause with no comma, only a space (Lion).
        public var pauseSpace = false
        /// A short pause as a comma with spaces round it (Leopard:
        /// "\"Configure\" ,  button" -- with the comma straight after the
        /// quote, or without the quotes, "button" is another sound).
        public var pauseSpacedComma = false
        /// Keep the caller's breaks and label text, without old Mac quoting.
        public var preserveRequestedPauses = false
        public static let snowLeopard = VoiceOverStyle(capitalTenths: 90, deletionTenths: -75, closingSilence: true, pauseSilence: true)
        public static let leopard = VoiceOverStyle(capitalTenths: 60, deletionTenths: -75, closingSilence: false, pauseSilence: false,
                                                   pauseSpacedComma: true)
        public static let lion = VoiceOverStyle(capitalTenths: 90, deletionTenths: -60, closingSilence: false, pauseSilence: false,
                                                pauseSpace: true)
#if CV_IOS10_ALEX
        public static let ios10Alex = VoiceOverStyle(capitalTenths: 90, deletionTenths: -60, closingSilence: false, pauseSilence: false,
                                                     pauseSpace: true, preserveRequestedPauses: true)
#endif
        public static func of(_ generation: Generation) -> VoiceOverStyle {
            switch generation {
            case .tiger, .leopard: return .leopard
            case .snowleopard: return .snowLeopard
            case .lion: return .lion
#if CV_IOS10_ALEX
            case .ios10Alex: return .ios10Alex
#endif
            }
        }
    }

    /// `macVoiceOver`: spelled characters, capitals and deletions as VoiceOver
    /// on Mac OS X wrote them (the voices always ask for it); `macPauses`
    /// (PantheraSettings.macPauses): its short pauses as silences.
    public func pieces(natural: Bool, wpm: Int, clauses: Bool = false, macVoiceOver: Bool = false, macPauses: Bool = false,
                       style: VoiceOverStyle = .snowLeopard, pausePercent: Int = 100) -> [Segment] {
        var segments = segments
        if macVoiceOver {
            for i in segments.indices {
                let spelled = segments[i].text.contains(Self.lettersOn)
                segments[i].pitchTenths = segments[i].pitchTenths.map { Self.macVoiceOverPitch($0, spelled: spelled, style: style) }
            }
        }
        var parts = natural ? Self.joined(segments, silences: macPauses && style.pauseSilence,
                                          space: macPauses && style.pauseSpace, quote: macPauses && !style.preserveRequestedPauses,
                                          spacedComma: macPauses && style.pauseSpacedComma,
                                          preserveLongPauses: macPauses,
                                          preserveRequestedPauses: macPauses && style.preserveRequestedPauses) : segments
        // Scale after joining so punctuation and grouping stay unchanged.
        // Before inlinePitch: character echo's closing cues keep their timing.
        if pausePercent != 100 {
            for i in parts.indices {
                parts[i].pauseAfterMs = Self.scaledPause(parts[i].pauseAfterMs, percent: pausePercent)
                parts[i].text = Self.scaledPauseMarks(parts[i].text, percent: pausePercent)
            }
        }
        if macVoiceOver { parts = parts.map { Self.inlinePitch($0, around: pitchTenths, style: style) } }
        return clauses ? Self.shortened(parts, wpm: wpm, longest: Self.clauseLongest) : parts
    }

    /// VoiceOver separates the parts of an announcement ("Outlook <break/>
    /// button") with short breaks.  Apple's voices -- and VoiceOver on the
    /// Mac, which sends "Outlook, button" -- make that a phrase break inside
    /// one utterance, so the pause follows the speaking rate and the
    /// intonation carries across.  Spoken as separate pieces with the break
    /// as fixed silence, the gaps stayed long at fast rates.  So: parts
    /// whose pause is shorter than `joinBelowMs` become one piece, joined
    /// with a comma unless the part already ends in punctuation; longer
    /// pauses still separate pieces, as silence of the length asked for.
    static let joinBelowMs = 600
    /// iOS VoiceOver hands a phone number over one digit per part, with a
    /// 17 ms break between the digits of a group and 255 ms between groups:
    /// "plus 1 <255/> 8 <17/> 1 <17/> 4 <255/> 4 <17/> 0 <17/> 9 <255/> ..."
    /// (Oct 23 log, Messages).  VoiceOver on the Mac hands over the number as
    /// written, "+1 (814) 409-8246", which the engines read as a phone number.
    /// So the digits are put back together the same way: digits under
    /// `groupBelowMs` apart are one group, and the groups are written as the
    /// number would have been.
    static let groupBelowMs = 100
    ///
    /// With `silences` (PantheraSettings.macPauses) the pause itself goes
    /// in too, before the comma, as VoiceOver on Mac OS X wrote it:
    /// "Finder [[slnc 60]] , running" (traced on Snow Leopard, Nov 5).  It
    /// travels as `pauseMark`, which Pronunciations.prepare turns into the
    /// command after embedded commands are filtered.
    /// The longest silence a joined pause gets: what VoiceOver on Mac OS X
    /// wrote for these ("[[slnc 60]] ,").
    static let macPauseMs = 60
    ///
    /// With `quote`, the part a short pause follows is put in quotation
    /// marks the first time another part joins it, as every traced
    /// VoiceOver on Mac OS X wrote an item's name before its role
    /// ("\"Help\" button", "\"Documents\" ,  folder"): the quotes change how
    /// the engine says what follows.
    static func joined(_ pieces: [Segment], silences: Bool = false, space: Bool = false,
                       quote: Bool = false, spacedComma: Bool = false, preserveLongPauses: Bool = false,
                       preserveRequestedPauses: Bool = false) -> [Segment] {
        var fresh = false              // the last piece in `out` has not been joined to yet
        var out: [Segment] = []
        var open = false               // the last piece in `out` takes more text
        var groups: [String] = []      // a number VoiceOver read digit by digit
        var gap = 0                    // the pause after its last digit
        var parts = 0                  // how many parts it came in
        func flush() {
            defer { groups = []; parts = 0 }
            guard !groups.isEmpty, var last = out.popLast() else { return }
            if parts == 1 {
                // One number in one part ("Volume <break/> 3"): an ordinary
                // part, joined as any other.
                let punctuated = last.text.last.map { ".,;:!?".contains($0) } ?? true
                last.text += (last.text.isEmpty ? "" : punctuated ? " " : ", ") + groups[0]
            } else {
                last.text = written(groups, after: last.text)
            }
            out.append(last)
        }
        for p in pieces {
            let t = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A part with no words ("6, , Yeah" in a log) adds only its pause.
            if t.isEmpty, open, var last = out.popLast() {
                last.pauseAfterMs = p.pauseAfterMs
                out.append(last)
                if !groups.isEmpty { gap = p.pauseAfterMs }
                open = p.pauseAfterMs < joinBelowMs
                continue
            }
            // A part at another pitch (a capital letter) is never joined to
            // its neighbours: the engine takes one pitch per utterance.
            if open, let last = out.last, last.pitchTenths != p.pitchTenths {
                flush()
                open = false
            }
            let digits = !t.isEmpty && t.count <= 4 && t.allSatisfy(\.isNumber)
            if digits && !preserveRequestedPauses && (open || out.isEmpty) {
                if out.isEmpty { out.append(Segment(text: "", pitchTenths: p.pitchTenths)) }
                if !groups.isEmpty && gap < groupBelowMs { groups[groups.count - 1] += t } else { groups.append(t) }
                parts += 1
                gap = p.pauseAfterMs
                out[out.count - 1].pauseAfterMs = p.pauseAfterMs
                open = p.pauseAfterMs < joinBelowMs
                continue
            }
            flush()
            if open, var last = out.popLast() {
                let name = last.text.trimmingCharacters(in: .whitespaces)
                if quote && fresh && !name.isEmpty && !name.contains("\"")
                    && (name.last.map { $0.isLetter || $0.isNumber } ?? false) {
                    last.text = "\"" + name + "\""
                }
                fresh = false
                let end = last.text.last
                let punctuated = end.map { ".,;:!?".contains($0) } ?? true
                let starts = t.first.map { ".,;:!?)".contains($0) } ?? false
                // iOS VoiceOver uses 276 ms for a short label/role boundary in
                // the captured requests. Keep its existing short-pause treatment.
                // Explicit 250/300/500 ms pauses in the Mac traces remain timed.
                if preserveRequestedPauses && last.pauseAfterMs > 0 {
                    last.text += " " + Self.pauseMark(last.pauseAfterMs) + " " + t
                } else if preserveLongPauses && last.pauseAfterMs >= 250 && last.pauseAfterMs != 276 {
                    // A timed silence does not replace the punctuation that
                    // tells MacinTalk how the following role should be phrased.
                    let separator = starts || punctuated || space ? " " : spacedComma ? " ,  " : " , "
                    last.text += " " + Self.pauseMark(last.pauseAfterMs) + separator + t
                } else if silences && last.pauseAfterMs > 0 {
                    last.text += " " + Self.pauseMark(min(last.pauseAfterMs, macPauseMs)) + (starts || punctuated ? " " : " , ") + t
                } else {
                    last.text += (starts ? "" : punctuated || space ? " " : spacedComma ? " ,  " : ", ") + t
                }
                last.pauseAfterMs = p.pauseAfterMs
                out.append(last)
            } else {
                out.append(Segment(text: t, pauseAfterMs: p.pauseAfterMs, pitchTenths: p.pitchTenths))
                fresh = true
            }
            open = p.pauseAfterMs < joinBelowMs
        }
        flush()
        return out
    }

    /// Reserve these scalars for marks created by the parser. Incoming text
    /// and pronunciation replacements cannot supply engine commands through them.
    public static func removingInternalMarks(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
            let value = scalar.value
            let reserved = (pauseMarkBase...pauseMarkBase + 0xFFFF).contains(value)
                || value == 0x100000 || value == 0x100001
                || (pitchMarkBase...pitchMarkBase + UInt32(2 * pitchMarkSpan)).contains(value)
                || value == pitchMarkNegativeZero
            return reserved ? Unicode.Scalar(32)! : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// A pause of `ms` inside a piece's text: one private-use character, so
    /// no rewriting of words or commands can split or remove it.
    static let pauseMarkBase: UInt32 = 0xF0000
    static func scaledPause(_ ms: Int, percent: Int) -> Int {
        Int((Double(min(0xFFFF, max(0, ms))) * Double(min(100, max(0, percent))) / 100).rounded())
    }
    private static func scaledPauseMarks(_ text: String, percent: Int) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if (pauseMarkBase...pauseMarkBase + 0xFFFF).contains(scalar.value) {
                let pause = scaledPause(Int(scalar.value - pauseMarkBase), percent: percent)
                if pause > 0 { result += pauseMark(pause) }
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
    static func pauseMark(_ ms: Int) -> String {
        String(Character(Unicode.Scalar(pauseMarkBase + UInt32(min(max(ms, 0), 0xFFFF)))!))
    }

    /// A pitch move inside a piece, in tenths of a semitone ("[[pbas +9.0]]").
    static let pitchMarkBase: UInt32 = 0x101000
    static let pitchMarkSpan = 240
    static let pitchMarkNegativeZero: UInt32 = pitchMarkBase + 0xFFF
    static func pitchMark(_ tenths: Int, negativeZero: Bool = false) -> String {
        if tenths == 0 && negativeZero { return String(Character(Unicode.Scalar(pitchMarkNegativeZero)!)) }
        let t = min(max(tenths, -pitchMarkSpan), pitchMarkSpan)
        return String(Character(Unicode.Scalar(pitchMarkBase + UInt32(t + pitchMarkSpan))!))
    }

    /// A piece at its own pitch, written as VoiceOver on Mac OS X wrote it:
    /// "[[pbas +9]]M[[pbas -9]][[slnc 60]] " in the one utterance, not the
    /// pitch set before it.  The move back and the silence end the piece:
    /// without them Alex drew the letter out 30 ms longer, another ending
    /// (Snow Leopard, "O" at 287 wpm: inline, correlation 1.000; set before,
    /// 0.003).
    static func inlinePitch(_ s: Segment, around base: Int, style: VoiceOverStyle = .snowLeopard) -> Segment {
        if s.text.contains(lettersOn) { return spelled(s, around: base, style: style) }
        let close = style.closingSilence ? pauseMark(60) + " " : ""
        guard let p = s.pitchTenths, p != base else { return s }
        var out = s
        // Raised (a capital), the pitch comes back before the silence;
        // lowered (deleted text), after it: "[[pbas -7.5]]s[[slnc 60]]
        // [[pbas +7.5]]", as traced.
        out.text = p > base
            ? pitchMark(p - base) + s.text + pitchMark(base - p) + close
            : pitchMark(p - base) + s.text + close + pitchMark(base - p)
        out.pitchTenths = nil
        return out
    }

    /// A character VoiceOver spells, in the form VoiceOver on Mac OS X gave
    /// it (traced on Snow Leopard, Nov 5) -- each a little different, and on
    /// Snow Leopard Alex each difference is heard ("[[pbas +0]]" around "o"
    /// and "e" changes them; the closing silence changes every letter):
    ///   a letter       [[pbas +0]]o[[pbas -0]][[slnc 60]]
    ///   anything else  1[[slnc 60]]
    ///   a capital      [[pbas +9]]M[[pbas -9]][[slnc 60]]
    ///   deleted        [[pbas -7.5]][[pbas +0]]s[[pbas -0]][[slnc 60]] [[pbas +7.5]]
    ///                  (a deleted digit without the [[pbas +0]] pair)
    /// Today's VoiceOver sends capitals in lower case, raised.
    static func spelled(_ s: Segment, around base: Int, style: VoiceOverStyle = .snowLeopard) -> Segment {
        var out = s
        let inner = s.text.unicodeScalars.filter { !($0.value >= 0x100000 && $0.value <= 0x100001) }
        let letter = String(String.UnicodeScalarView(inner)).trimmingCharacters(in: .whitespaces)
            .first.map { $0.isLetter } ?? false
        let p = s.pitchTenths ?? base
        let close = style.closingSilence ? pauseMark(60) + " " : ""
        if p > base {
            out.text = pitchMark(p - base) + s.text + pitchMark(base - p) + close
        } else {
            let zeroed = letter ? pitchMark(0) + s.text + pitchMark(0, negativeZero: true) : s.text
            out.text = p < base ? pitchMark(p - base) + zeroed + close + pitchMark(base - p) : zeroed + close
        }
        out.pitchTenths = nil
        return out
    }

    /// Letter mode on and off around a `<say-as interpret-as="characters">`.
    static let lettersOn = String(Character(Unicode.Scalar(0x100000)!))
    static let lettersOff = String(Character(Unicode.Scalar(0x100001)!))

    /// `text` cut at its marks: each part, and the engine command its mark
    /// stands for (nil after the last).  Letter mode left on is switched off
    /// at the end, as the engine would otherwise keep it for good.
    public static func splitAtMarks(_ text: String) -> [(text: String, command: String?)] {
        var out: [(String, String?)] = []
        var part = ""
        var spelling = false
        for s in text.unicodeScalars {
            let command: String
            if s.value >= pauseMarkBase && s.value <= pauseMarkBase + 0xFFFF {
                command = "[[slnc \(s.value - pauseMarkBase)]]"
            } else if s.value == pitchMarkNegativeZero {
                command = "[[pbas -0.0]]"
            } else if s.value >= pitchMarkBase && s.value <= pitchMarkBase + UInt32(2 * pitchMarkSpan) {
                let tenths = Int(s.value - pitchMarkBase) - pitchMarkSpan
                command = "[[pbas " + String(format: "%+.1f", Double(tenths) / 10) + "]]"
            } else if s.value == 0x100000 {
                spelling = true; command = "[[char LTRL]]"
            } else if s.value == 0x100001 {
                spelling = false; command = "[[char NORM]]"
            } else {
                part.unicodeScalars.append(s)
                continue
            }
            out.append((part, command))
            part = ""
        }
        out.append((part, spelling ? "[[char NORM]]" : nil))
        return out
    }

    /// VoiceOver's pitch for a capital letter (+50%) and for deleted text
    /// (-30%), as VoiceOver on Mac OS X set them: "[[pbas +9]]" and
    /// "[[pbas -7.5]]" (traced on Snow Leopard, Nov 5).  Other changes stay.
    ///
    /// On the Mac today's VoiceOver lowers a deleted letter by 40% (its log,
    /// Nov 5); 40% is also its placeholder text, which nothing traced
    /// matches, so that stays unless the piece is a spelled letter.
    static func macVoiceOverPitch(_ tenths: Int, spelled: Bool = false, style: VoiceOverStyle = .snowLeopard) -> Int {
        if tenths == pitch("+50%") { return style.capitalTenths }
        if tenths == pitch("-30%") || (spelled && tenths == pitch("-40%")) { return style.deletionTenths }
        return tenths
    }

    /// `text` followed by the number VoiceOver spelled out as `groups`, as
    /// it is written: "+1 (814) 409-8246" for a North American number, the
    /// groups with spaces between them otherwise ("+44 20 7946 0958").  A
    /// "plus N" at the end of `text` is VoiceOver's reading of "+N".
    static func written(_ groups: [String], after text: String) -> String {
        var head = text
        var country: String?
        if let r = head.range(of: #"(?i)plus\s+(\d{1,3})$"#, options: .regularExpression) {
            country = String(head[r].split(separator: " ").last ?? "")
            head = String(head[..<r.lowerBound])
        }
        var number: String
        let lengths = groups.map(\.count)
        if lengths == [3, 3, 4] {
            number = "(\(groups[0])) \(groups[1])-\(groups[2])"
        } else if lengths == [3, 4] {
            number = "\(groups[0])-\(groups[1])"
        } else {
            number = groups.joined(separator: " ")
        }
        if let c = country { number = "+\(c) " + number }
        let space = head.isEmpty || head.last!.isWhitespace ? "" : " "
        return head + space + number
    }

    /// Long pieces cut between sentences, so an interruption does not wait.
    ///
    /// When VoiceOver interrupts, the engine has to finish rendering the
    /// utterance it is working on before the next request can start
    /// (measured, Oct 22: a stop 0.2 s into 520 characters of Lion Alex
    /// waited for all of it), so a long paragraph cost seconds of silence
    /// after a swipe.  But every cut is a new utterance, and the engine reads
    /// each one on its own: a word it would have given less stress because it
    /// came up a moment before ("...went to the store. Then I went home")
    /// gets full stress again, and a cut at a comma ends the clause the way a
    /// sentence ends.  So by default pieces are whole sentences -- as many as
    /// fit in `longest` characters, and one sentence however long -- and only
    /// with quick interruptions (`clauses`) is a long sentence cut at its
    /// commas too.  A cut loses the engine's own pause there, so it gets one
    /// of the length the engine makes at this rate (measured: about 260 ms
    /// after a sentence and 220 ms at a comma at 180 wpm, shrinking in
    /// proportion as the rate rises).
    static let longest = 90
    /// With quick interruptions (PantheraSettings.quickInterrupt): pieces over
    /// this are cut at their clauses, none shorter than `clauseShortest`.
    static let clauseLongest = 40
    static let clauseShortest = 12
    static func shortened(_ pieces: [Segment], wpm: Int, longest: Int = SSMLRequest.longest) -> [Segment] {
        let scale = 180.0 / Double(max(wpm, 80))
        var out: [Segment] = []
        for p in pieces {
            let parts = longest == Self.longest ? sentences(p.text, longest: longest) : split(p.text, longest: longest)
            for (k, t) in parts.enumerated() {
                let last = k == parts.count - 1
                let sentence = t.last.map { ".!?".contains($0) } ?? false
                let made = Int(((sentence ? 260.0 : 220.0) * scale).rounded())
                out.append(Segment(text: t, pauseAfterMs: last ? p.pauseAfterMs : made, pitchTenths: p.pitchTenths))
            }
        }
        return out
    }

    /// Words a period follows without ending the sentence: "Dr. Smith",
    /// "Jan. 5", "vs. them".  A single letter ("J. Smith", "U.S.", "e.g.")
    /// counts too.  Missing one only costs a cut; wrongly cutting after one
    /// makes the engine end a sentence on "Dr.".
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "no", "nos", "fig", "vol",
        "ch", "mt", "ft", "inc", "ltd", "co", "corp", "gov", "gen", "capt", "sgt", "lt", "col",
        "rev", "ave", "blvd", "rd", "approx", "dept", "est", "min", "max", "pp", "jan", "feb",
        "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "mon", "tue",
        "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun", "op", "al", "cf", "ca"]

    /// Is the `.`, `!` or `?` at `mark` the end of a sentence?  `next` is
    /// where the text goes on after it (past closing quotes and the space).
    static func endsSentence(_ text: Substring, mark: String.Index, next: String.Index) -> Bool {
        // What follows must start one: a capital, a digit, or an opening mark.
        guard let first = text[next...].first(where: { !$0.isWhitespace }),
              first.isUppercase || first.isNumber || "\"'([“‘".contains(first) else { return false }
        guard text[mark] == "." else { return true }                     // ! or ?
        let word = String(text[..<mark].reversed().prefix { $0.isLetter }.reversed())
        if word.count == 1 { return false }                              // an initial
        return !abbreviations.contains(word.lowercased())
    }

    /// Where the sentences of `text` end: each index is just past one's end
    /// (its closing quotes and the space after).
    static func sentenceEnds(_ text: Substring) -> [String.Index] {
        var ends: [String.Index] = []
        var i = text.startIndex
        while i < text.endIndex {
            if ".!?".contains(text[i]) {
                var j = text.index(after: i)
                while j < text.endIndex && "\"')]”’".contains(text[j]) { j = text.index(after: j) }
                if j < text.endIndex && text[j].isWhitespace {
                    let next = text.index(after: j)
                    if next < text.endIndex && endsSentence(text, mark: i, next: next) { ends.append(next) }
                }
                i = j
            } else {
                i = text.index(after: i)
            }
        }
        return ends
    }

    /// Whole sentences, joined while they fit in `longest` characters; a
    /// sentence longer than that is a piece of its own, uncut.
    static func sentences(_ text: String, longest: Int = SSMLRequest.longest) -> [String] {
        guard text.count > longest else { return [text] }
        let all = Substring(text)
        var parts: [String] = []
        var from = all.startIndex
        var fits = all.startIndex                 // the latest end within `longest` of `from`
        for end in sentenceEnds(all) + [all.endIndex] {
            if fits > from && all.distance(from: from, to: end) > longest {
                parts.append(all[from..<fits].trimmingCharacters(in: .whitespaces))
                from = fits
            }
            fits = end
        }
        let tail = all[from...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        let kept = parts.filter { !$0.isEmpty }
        return kept.isEmpty ? [text] : kept
    }

    /// Quick interruptions: cut at the last sentence end in `longest`
    /// characters, else at the last comma, semicolon or colon, never in the
    /// first `clauseShortest`.
    static func split(_ text: String, longest: Int = SSMLRequest.longest) -> [String] {
        guard text.count > longest else { return [text] }
        let shortest = longest == Self.longest ? 25 : clauseShortest
        var parts: [String] = []
        var rest = Substring(text)
        while rest.count > longest {
            let window = rest.prefix(longest)
            var cut: String.Index?
            for marks in [[". ", "! ", "? "], [", ", "; ", ": "]] {
                var best: String.Index?
                for m in marks {
                    var search = window.startIndex..<window.endIndex
                    while let r = window.range(of: m, options: .backwards, range: search) {
                        search = window.startIndex..<r.lowerBound
                        guard window.distance(from: window.startIndex, to: r.lowerBound) >= shortest else { break }
                        // A period after "Dr" or an initial is not a sentence end.
                        if m == ". " && !endsSentence(rest, mark: r.lowerBound, next: r.upperBound) { continue }
                        if best == nil || r.upperBound > best! { best = r.upperBound }
                        break
                    }
                }
                if let b = best { cut = b; break }
            }
            guard let c = cut else { break }
            let head = rest[..<c].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { parts.append(head) }
            rest = rest[c...]
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [text] : parts
    }

    /// Pause-only pieces fold into the one before; a pause is capped at a
    /// second; the last piece's trailing pause is dropped.
    private static func boundedPause(_ ms: Int) -> Int { min(max(ms, 0), 1000) }

    private static func addingPauses(_ a: Int, _ b: Int) -> Int {
        min(boundedPause(a) + boundedPause(b), 1000)
    }

    static func merged(_ pieces: [Segment], preserveTrailingPause: Bool = false) -> [Segment] {
        var out: [Segment] = []
        for p in pieces {
            let blank = p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if blank {
                if !out.isEmpty { out[out.count - 1].pauseAfterMs = addingPauses(out[out.count - 1].pauseAfterMs, p.pauseAfterMs) }
                continue
            }
            out.append(Segment(text: p.text, pauseAfterMs: boundedPause(p.pauseAfterMs), pitchTenths: p.pitchTenths))
        }
        for i in out.indices { out[i].pauseAfterMs = min(out[i].pauseAfterMs, 1000) }
        if !preserveTrailingPause && !out.isEmpty { out[out.count - 1].pauseAfterMs = 0 }
        return out
    }

    /// `<break time="250ms"/>`, `time="1s"`, or a strength.
    static func breakMs(time: String?, strength: String?) -> Int {
        if let t = time?.trimmingCharacters(in: .whitespaces).lowercased() {
            if t.hasSuffix("ms"), let v = Double(t.dropLast(2)) { return v.isFinite ? Int(min(max(v, 0), 1000)) : 0 }
            if t.hasSuffix("s"), let v = Double(t.dropLast()) { return v.isFinite ? Int(min(max(v, 0), 1) * 1000) : 0 }
        }
        switch strength?.lowercased() {
        case "none": return 0
        case "x-weak": return 50
        case "weak": return 100
        case "strong": return 500
        case "x-strong": return 1000
        default: return 250                                    // medium, or a bare <break/>
        }
    }

    // MARK: - SSML values

    static func rate(_ raw: String) -> Double? {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch v {
        case "x-slow": return 0.5
        case "slow": return 0.75
        case "medium", "default": return 1
        case "fast": return 1.5
        case "x-fast": return 2
        default: break
        }
        if v.hasSuffix("%"), let n = Double(v.dropLast().replacingOccurrences(of: "+", with: "")) {
            // "+20%" is relative; "120%" is absolute. Both mean 1.2 here.
            let relative = v.hasPrefix("+") || v.hasPrefix("-")
            let m = relative ? 1 + n / 100 : n / 100
            return m.isFinite && m > 0 ? m : nil
        }
        if let n = Double(v), n.isFinite, n > 0 { return n }                          // a bare multiplier
        return nil
    }

    /// SSML 1.1 volume: decibels ("-1.94dB", "+6dB"), a keyword, a
    /// relative percentage ("+10%"), or SSML 1.0's 0...100 (100 is normal).
    /// Capped at +6 dB, so a request cannot push the samples far past full.
    static func gain(_ raw: String) -> Float? {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var db: Double?
        switch v {
        case "silent": return 0
        case "x-soft": db = -12
        case "soft": db = -6
        case "medium", "default": db = 0
        case "loud": db = 6
        case "x-loud": db = 6
        default:
            if v.hasSuffix("db"), let n = Double(v.dropLast(2).replacingOccurrences(of: "+", with: "")) {
                db = n
            } else if v.hasSuffix("%"), let n = Double(v.dropLast().replacingOccurrences(of: "+", with: "")) {
                let ratio = (v.hasPrefix("+") || v.hasPrefix("-")) ? 1 + n / 100 : n / 100
                return ratio > 0 ? Float(min(ratio, 2)) : 0
            } else if let n = Double(v), n >= 0 {
                return Float(min(n / 100, 2))
            }
        }
        guard let d = db, d.isFinite else { return nil }
        return Float(pow(10, min(d, 6) / 20))
    }

    static func pitch(_ raw: String) -> Int? {
        let v = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let tenths: Double
        switch v {
        case "x-low": tenths = -60
        case "low": tenths = -30
        case "medium", "default": tenths = 0
        case "high": tenths = 30
        case "x-high": tenths = 60
        default:
            if v.hasSuffix("st"), let n = Double(v.dropLast(2).replacingOccurrences(of: "+", with: "")) {
                tenths = n * 10
            } else if v.hasSuffix("%"), let n = Double(v.dropLast().replacingOccurrences(of: "+", with: "")) {
                let relative = v.hasPrefix("+") || v.hasPrefix("-")
                let ratio = relative ? 1 + n / 100 : n / 100
                guard ratio > 0 else { return nil }
                // A ratio is a logarithm away from semitones, as on Android.
                tenths = 120 * log2(ratio)
            } else {
                return nil                                             // Hz: no voice-relative meaning
            }
        }
        guard tenths.isFinite else { return nil }
        return Int(min(max(tenths.rounded(), -120), 120))
    }

    static func stripTags(_ ssml: String) -> String {
        ssml.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The outermost `<prosody>` rate, pitch and volume, and the text cut into
/// segments at its `<break>`s -- and wherever a `<prosody pitch>` inside it
/// changes the pitch (a capital letter, deleted text), each such part a
/// segment with that pitch.  Nested rate changes are not followed: the engine
/// takes one rate per utterance.
private final class ProsodyReader: NSObject, XMLParserDelegate {
    var rate: String?
    var pitch: String?
    var volume: String?
    var segments: [SSMLRequest.Segment] = []
    var parsed = false
    var requiresLegacyParser = false
    private var hasSpokenText = false
    private var current = ""
    /// Per open `<prosody>`, the pitch in force inside it: nil while it is the
    /// request's own (the outermost element's), else tenths from the voice.
    private var pitches: [Int?] = []
    private var currentPitch: Int? { pitches.last ?? nil }
    /// The outermost pitch in tenths, the base a nested relative value moves.
    private var basePitch = 0

    private func cut(pauseAfterMs: Int = 0) {
        segments.append(.init(text: current, pauseAfterMs: pauseAfterMs, pitchTenths: currentPitch))
        current = ""
    }

    init(_ ssml: String) {
        super.init()
        guard let data = ssml.data(using: .utf8) else { return }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parsed = parser.parse()
        segments.append(.init(text: current, pitchTenths: currentPitch))
    }

    /// Per open `<say-as>`, whether it spells (interpret-as="characters").
    private var spelling: [Bool] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let localName = name.split(separator: ":").last.map(String.init) ?? name
        if ["mark", "phoneme", "lang", "s", "p"].contains(localName) { requiresLegacyParser = true }
        if localName == "prosody", (attributes["rate"] != nil || attributes["volume"] != nil),
           hasSpokenText || !pitches.isEmpty { requiresLegacyParser = true }
        if name == "break" || name.hasSuffix(":break") {
            cut(pauseAfterMs: SSMLRequest.breakMs(time: attributes["time"], strength: attributes["strength"]))
            return
        }
        if name == "say-as" || name.hasSuffix(":say-as") {
            // A letter VoiceOver reads by itself: in the engine's letter mode,
            // as VoiceOver on Mac OS X sent it ("[[char LTRL]]a[[char NORM]]"),
            // or a lone "a" is the word, not the letter.
            let spells = ["characters", "spell-out"].contains(attributes["interpret-as"]?.lowercased() ?? "")
            if spells { current += SSMLRequest.lettersOn }
            spelling.append(spells)
            return
        }
        guard name == "prosody" || name.hasSuffix(":prosody") else { return }
        if pitches.isEmpty {
            // The outermost element: the request's own rate, pitch and volume.
            rate = attributes["rate"]
            pitch = attributes["pitch"]
            volume = attributes["volume"]
            basePitch = pitch.flatMap(SSMLRequest.pitch(_:)) ?? 0
            pitches.append(nil)
            return
        }
        if rate == nil { rate = attributes["rate"] }
        if volume == nil { volume = attributes["volume"] }
        var inner = currentPitch
        if let raw = attributes["pitch"], let tenths = SSMLRequest.pitch(raw) {
            // "+20%" or "+2st" moves the pitch around it; "120%", "high" set it.
            let v = raw.trimmingCharacters(in: .whitespaces)
            let relative = v.hasPrefix("+") || v.hasPrefix("-")
            let around = currentPitch ?? basePitch
            let value = min(max(relative ? around + tenths : tenths, -120), 120)
            inner = value == basePitch && currentPitch == nil ? nil : value
        }
        if inner != currentPitch, !current.isEmpty { cut() }
        pitches.append(inner)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if (name == "voice" || name.hasSuffix(":voice")), let last = current.last, !last.isWhitespace {
            current += " "  // retain Classic's In + list view boundary fix
        }
        if (name == "say-as" || name.hasSuffix(":say-as")), let spells = spelling.popLast() {
            if spells { current += SSMLRequest.lettersOff }
            return
        }
        guard name == "prosody" || name.hasSuffix(":prosody"), !pitches.isEmpty else { return }
        let outer = pitches.count > 1 ? pitches[pitches.count - 2] : nil
        // The text inside ends with the inner pitch, before it is closed.
        if outer != currentPitch, !current.isEmpty { cut() }
        pitches.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { hasSpokenText = true }
        current += SSMLRequest.removingInternalMarks(string)
    }
}
