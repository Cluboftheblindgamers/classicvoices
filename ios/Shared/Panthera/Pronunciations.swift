// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation

/// One entry in the pronunciation list: whenever `match` appears in what is
/// being spoken, the engine hears `replacement` instead.
///
/// The engines' own dictionaries are inside Apple's data and are not ours to
/// edit, so corrections live here, in the app, and apply to selected generations
/// or individual voices without touching the imported files.
public struct Pronunciation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    /// The word or phrase as it is written: "Giulia", "1 minute".
    public var match: String = ""
    /// What to say instead: ordinary spelling ("Julia"), or MacinTalk
    /// phonemes ("J1UWlIYAX") when `phonemes` is on.
    public var replacement: String = ""
    public var phonemes = false
    public var matchCase = false
    /// Off: also inside longer words ("Giulia" in "Giulianova").
    public var wholeWords = true
    /// Empty: every generation.
    public var generations: Set<Generation> = []
    /// nil: use generations. A set: only these stable Panthera voice IDs.
    /// An empty set deliberately applies nowhere, never to every voice.
    public var voiceIDs: Set<String>?

    public init() {}

    public init(match: String, replacement: String, phonemes: Bool = false) {
        self.match = match
        self.replacement = replacement
        self.phonemes = phonemes
    }

    private enum CodingKeys: String, CodingKey {
        case id, match, replacement, phonemes, matchCase, wholeWords, generations, voiceIDs
    }

    /// Every field optional, so a list saved by an older or newer build loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        match = try c.decodeIfPresent(String.self, forKey: .match) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        phonemes = try c.decodeIfPresent(Bool.self, forKey: .phonemes) ?? false
        matchCase = try c.decodeIfPresent(Bool.self, forKey: .matchCase) ?? false
        wholeWords = try c.decodeIfPresent(Bool.self, forKey: .wholeWords) ?? true
        let names = try c.decodeIfPresent([String].self, forKey: .generations) ?? []
        generations = Set(names.compactMap(Generation.init(rawValue:)))
        voiceIDs = try c.decodeIfPresent([String].self, forKey: .voiceIDs).map(Set.init)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(match, forKey: .match)
        try c.encode(replacement, forKey: .replacement)
        try c.encode(phonemes, forKey: .phonemes)
        try c.encode(matchCase, forKey: .matchCase)
        try c.encode(wholeWords, forKey: .wholeWords)
        try c.encode(generations.map(\.rawValue).sorted(), forKey: .generations)
        try c.encodeIfPresent(voiceIDs.map { $0.sorted() }, forKey: .voiceIDs)
    }

    public func applies(to gen: Generation, voiceID: String? = nil) -> Bool {
        guard let selected = voiceIDs else { return generations.isEmpty || generations.contains(gen) }
        guard let voiceID else { return false }
        let prefix = "com.pantheraspeech.\(gen.rawValue)."
        if voiceID.hasPrefix(prefix) { return selected.contains(voiceID) }
        // System voice identifiers can have an extension bundle prefix.
        return selected.contains { $0.hasPrefix(prefix) && voiceID.hasSuffix("." + $0) }
    }

    public var isUsable: Bool {
        !match.trimmingCharacters(in: .whitespaces).isEmpty
            && !replacement.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The phoneme string as the engine should get it: no brackets, which
    /// would end the input mode early and leave the engine reading phonemes
    /// as text (or text as phonemes) for the rest of the utterance.
    var cleanPhonemes: String {
        SSMLRequest.removingInternalMarks(replacement).replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var regex: NSRegularExpression? {
        let core = NSRegularExpression.escapedPattern(for: match.trimmingCharacters(in: .whitespaces))
            // Any run of spaces in the entry matches any run of spaces spoken.
            .replacingOccurrences(of: " ", with: "\\s+")
        let pattern = wholeWords ? "(?<![\\p{L}\\p{N}])" + core + "(?![\\p{L}\\p{N}])" : core
        return try? NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive])
    }
}

/// The list, kept in the shared App Group defaults: the app edits it and
/// every speech extension reads it.
public enum Pronunciations {
    public static let key = "pronunciations"

    public static func load(from defaults: UserDefaults = AppGroup.defaults) -> [Pronunciation] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return cache.entries(for: data)
    }

    public static func save(_ entries: [Pronunciation], to defaults: UserDefaults = AppGroup.defaults) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }

    /// One piece of text after the list is applied.
    public enum Span: Equatable {
        case text(String)
        case phonemes(String)
    }

    /// Split `text` into what is ordinary text and what the list says to speak
    /// as phonemes.  Longest entries go first, so "1 minute" is matched before
    /// "minute" can claim half of it; replaced text is never matched again.
    public static func apply(_ entries: [Pronunciation], to text: String, generation: Generation,
                             voiceID: String? = nil) -> [Span] {
        let active = entries
            .filter { $0.isUsable && $0.applies(to: generation, voiceID: voiceID) }
            .sorted {
                if $0.match.count != $1.match.count { return $0.match.count > $1.match.count }
                // A voice-specific exception wins over a same-length general
                // correction, without changing existing generation-only order.
                return $0.voiceIDs != nil && $1.voiceIDs == nil
            }
        guard !active.isEmpty else { return [.text(text)] }

        // Ordinary-text pieces stay open to later entries; replacements are done.
        enum Piece { case open(String), done(Span) }
        var pieces: [Piece] = [.open(text)]
        for entry in active {
            guard let regex = cache.regex(for: entry) else { continue }
            var next: [Piece] = []
            for piece in pieces {
                guard case .open(let s) = piece else { next.append(piece); continue }
                let ns = s as NSString
                var at = 0
                for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                    if m.range.location > at {
                        next.append(.open(ns.substring(with: NSRange(location: at, length: m.range.location - at))))
                    }
                    next.append(.done(entry.phonemes ? .phonemes(entry.cleanPhonemes) : .text(SSMLRequest.removingInternalMarks(entry.replacement))))
                    at = m.range.location + m.range.length
                }
                if at < ns.length { next.append(.open(ns.substring(from: at))) }
            }
            pieces = next
        }

        // Neighbouring text pieces become one again, so the rest of the text
        // preparation (abbreviations, emoji) sees them as they were written.
        var out: [Span] = []
        for piece in pieces {
            let span: Span
            switch piece {
            case .open(let s): span = .text(s)
            case .done(let d): span = d
            }
            if case .text(let s) = span, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + s)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// Text -> what the engine hears: the list first, then SpeechText.prepare
    /// on the ordinary text.  Phoneme entries are wrapped in input-mode
    /// commands here, after prepare, so turning embedded commands off (which
    /// strips commands the user typed) leaves them alone.
    public static func prepare(_ text: String, entries: [Pronunciation], settings: PantheraSettings,
                               generation: Generation, voiceID: String? = nil, internalMarks: Bool = false) -> String {
        let text = internalMarks ? text : SSMLRequest.removingInternalMarks(text)
        var out = ""
        var spelling = false
        for span in apply(entries, to: text, generation: generation, voiceID: voiceID) {
            switch span {
            case .text(let s):
                // VoiceOver's pauses and letters (SSMLRequest's marks) become
                // commands here, whether or not embedded commands are accepted.
                for part in SSMLRequest.splitAtMarks(s) {
                    out += SpeechText.prepare(part.text, settings: settings, generation: generation, spelling: spelling)
                    if let command = part.command {
                        out += command
                        if command == "[[char LTRL]]" { spelling = true }
                        if command == "[[char NORM]]" { spelling = false }
                    }
                }
            case .phonemes(let p):
                guard !p.isEmpty else { continue }
                // Spaces keep the phonemes from running into the neighbouring
                // words, which the engine would otherwise read as one.
                out += " [[inpt PHON]]" + p + "[[inpt TEXT]] "
            }
        }
        // A command the person's text brought lasts this piece only
        // (PantheraSettings.resetCommands): reset after it, never before, as
        // the rate and pitch are set before the text is spoken.  A command
        // dropped for the generation (Lion's input modes) resets nothing.
        if settings.acceptCommands && settings.resetCommands && SpeechText.hasCommand(text)
            && out.contains("[[") {
            out += " [[rset 0]]"
        }
        return out
    }

    // MARK: - Decoding and regexes, once per change rather than per utterance

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?
        private var decoded: [Pronunciation] = []
        private var regexes: [String: NSRegularExpression] = [:]

        func entries(for data: Data) -> [Pronunciation] {
            lock.lock(); defer { lock.unlock() }
            if data != self.data {
                self.data = data
                decoded = (try? JSONDecoder().decode([Pronunciation].self, from: data)) ?? []
            }
            return decoded
        }

        func regex(for entry: Pronunciation) -> NSRegularExpression? {
            let k = "\(entry.matchCase)|\(entry.wholeWords)|\(entry.match)"
            lock.lock(); defer { lock.unlock() }
            if let r = regexes[k] { return r }
            guard let r = entry.regex else { return nil }
            if regexes.count > 512 { regexes.removeAll() }
            regexes[k] = r
            return r
        }
    }
}
