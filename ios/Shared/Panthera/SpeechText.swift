// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation
import NaturalLanguage

/// The text the engine should hear: a port of Android's SpeechTextOptions
/// (itself the lexical half of the NVDA driver's pantheraabbrev.py). Number
/// handling and dictionary abbreviations live in the host, shared by every
/// front end, and are switched with panthera_set_number_style and
/// panthera_set_expand_abbreviations.
///
/// The whole request goes to the engine as one utterance, as on Android and
/// NVDA: sentence breaks inside one utterance are where Alex breathes.
public enum SpeechText {
    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are constants; a typo should fail loudly in development.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let commands = re(#"\[\s*\[[^\]]{0,64}\]\s*\]"#)
    private static let inputMode = re(#"^\[\[\s*inpt\s+[A-Za-z]{0,16}\s*\]\]$"#, [.caseInsensitive])
    private static let acronyms = re(#"\b(DR|ST|MR|MRS|JR|SR|FT|RD|CT|VS|ETC)\b"#)
    private static let titles = re(#"\b(Prof|Capt|Blvd|Mrs|Gen|Sen|Rep|Gov|Ave|Dr|St|Mr|Ms|Lt|Jr|Sr|Rd|Ft|Ct)\b"#)
    private static let units = re(#"\b(\d+)\s?(mm|cm|km|kg|g|m)\b"#)
    private static let roman = re(#"\b(?=[MDCLXVI]{2,}\b)(M{0,3}(?:CM|CD|D?C{0,3})(?:XC|XL|L?X{0,3})(?:IX|IV|V?I{0,3}))\b"#)
    private static let doctor = re(#"\bDr\.(\s+)(?=[A-Z][a-z])"#)
    private static let possessiveX = re(#"\bX(['’]s)\b"#)
    /// A run of hex digits with letters and digits both in it, long enough (20 or more)
    /// that it is an identifier rather than a word: "711495d10bb643f6...".
    private static let identifier = re(#"(?<![\p{L}\p{N}])(?=[0-9A-Fa-f]*[0-9])(?=[0-9A-Fa-f]*[A-Fa-f])[0-9A-Fa-f]{20,}(?![\p{L}\p{N}])"#)

    /// Replace every match of `regex` with what `transform` returns.
    private static func replace(_ regex: NSRegularExpression, in text: String,
                                _ transform: (_ match: NSTextCheckingResult, _ ns: NSString) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var at = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += transform(m, ns)
            at = m.range.location + m.range.length
        }
        out += ns.substring(from: at)
        return out
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String {
        let r = m.range(at: i)
        return r.location == NSNotFound ? "" : ns.substring(with: r)
    }

    private static func letters(_ s: String) -> String {
        s.uppercased().map { String($0) }.joined(separator: " ")
    }

    static func abbreviations(_ text: String, expand: Bool) -> String {
        var out = replace(possessiveX, in: text) { m, ns in "ex" + group(m, 1, ns) }
        if expand {
            return replace(doctor, in: out) { m, ns in "Doctor" + group(m, 1, ns) }
        }
        out = replace(acronyms, in: out) { m, ns in letters(group(m, 0, ns)) }
        out = replace(titles, in: out) { m, ns in letters(group(m, 0, ns)) }
        out = replace(units, in: out) { m, ns in group(m, 1, ns) + " " + letters(group(m, 2, ns)) }
        return replace(roman, in: out) { m, ns in
            let v = group(m, 0, ns)
            return v == "MIX" ? v : letters(v)
        }
    }

    // Short day and month names, title case or capitals, only where they
    // are plainly part of a date: before a number or a month ("Fri Oct 23",
    // "Fri, 9:32 AM", "Oct. 23"), a month after a day number ("23 Oct"), or a
    // day name on its own (a calendar's column, "Fri").  "Sat down", "Sun
    // and moon", "Jan said" are left alone.  A period after the short name is
    // taken with it, so "Fri." does not become the end of a sentence.
    private static let dayNames: [String: String] = [
        "mon": "Monday", "tue": "Tuesday", "tues": "Tuesday", "wed": "Wednesday", "thu": "Thursday",
        "thur": "Thursday", "thurs": "Thursday", "fri": "Friday", "sat": "Saturday", "sun": "Sunday"]
    private static let monthNames: [String: String] = [
        "jan": "January", "feb": "February", "mar": "March", "apr": "April", "jun": "June",
        "jul": "July", "aug": "August", "sep": "September", "sept": "September", "oct": "October",
        "nov": "November", "dec": "December"]
    private static let dayAlt = #"Mon|Tues?|Wed|Thu(?:rs?)?|Fri|Sat|Sun|MON|TUES?|WED|THU(?:RS?)?|FRI|SUN"#
    private static let monthAlt = #"Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept?|Oct|Nov|Dec|JAN|FEB|MAR|APR|JUN|JUL|AUG|SEPT?|OCT|NOV|DEC"#
    private static let monthFull = #"January|February|March|April|May|June|July|August|September|October|November|December"#
    private static let dayBeforeDate = re(#"\b("# + dayAlt + #")\.?(?=,?\s+(?:\d|(?:"# + monthAlt + "|" + monthFull + #")\b))"#)
    private static let dayAlone = re(#"^(\s*)("# + dayAlt + #")(\.?\s*)$"#)
    private static let monthBeforeNumber = re(#"\b("# + monthAlt + #")\.?(?=\s+\d)"#)
    private static let monthAfterDay = re(#"(?<=\b\d{1,2}\s)("# + monthAlt + #")\b\.?"#)

    /// A word all in capitals, five letters or more, with a vowel; not a
    /// Roman numeral (those are spelled out on purpose, `roman`).
    /// Digits may follow ("JANESMITH4", a user name): still a word.
    /// A sentence end with a comma after it: iOS VoiceOver writes "Use the
    /// lock button.," before the next part of an announcement, and Leopard
    /// spells the word in front of ".," letter by letter (its phonemes: "b
    /// y t t o n"; Snow Leopard reads it).  The sentence end stays.
    private static let stopThenComma = re(#"([.!?])(\s*,)+"#)
    static func tidyPunctuation(_ text: String) -> String {
        replace(stopThenComma, in: text) { m, ns in group(m, 1, ns) }
    }

    /// Words the engines read wrong before a number (the owner, Nov 5):
    /// Receipt labels, including Messages’ direction mark and VoiceOver text role,
    /// use past tense ("Read 10:45 AM"), but every generation says
    /// "reed". Ordinary instructions such as "Read 3 chapters" stay unchanged. Tiger, Leopard and Snow Leopard say "minute 3" as my-NOOT.  Respelled: "red"
    /// everywhere, "minnitt" before a number on those three generations. Lion
    /// already chooses the duration pronunciation and stays unchanged.
    private static let readBeforeNumber = re(#"(^[\h\u200E\u200F\u061C"“]*|,[\h\u200E\u200F\u061C"“]*|[\u200E\u200F\u061C][\h\u200E\u200F\u061C"“]*)([Rr])ead(?=\h+(?:[01]?\d|2[0-3]):[0-5]\d(?:\h*[AaPp][Mm])?[\h\u200E\u200F\u061C"”]*(?:,?\h*[Tt]ext)?\h*$)"#)
    private static let minuteBeforeNumber = re(#"\b([Mm])inute(?=\s+\d)"#)
    static func beforeNumbers(_ text: String, generation: Generation) -> String {
        let read = replace(readBeforeNumber, in: text) { m, ns in group(m, 1, ns) + group(m, 2, ns) + "ed" }
        guard generation != .lion else { return read }
        return replace(minuteBeforeNumber, in: read) { m, ns in group(m, 1, ns) + "innitt" }
    }

    /// Paired abbreviated time units are durations; a lone "m" can mean metres.
    /// Keep capitals, identifiers and fractional-unit expressions unchanged.
    private static let shortDuration = re(#"(?<![\p{L}\p{N}_.])(?:(\d+)\h*h\h*)?(\d+)\h*m\h*(\d+)\h*s(?![\p{L}\p{N}_])"#)
    static func expandDurations(_ text: String) -> String {
        replace(shortDuration, in: text) { m, ns in
            func unit(_ count: String, _ name: String) -> String {
                count + " " + name + (Int(count) == 1 ? "" : "s")
            }
            let hours = group(m, 1, ns)
            let minutes = group(m, 2, ns)
            let seconds = group(m, 3, ns)
            return (hours.isEmpty ? "" : unit(hours, "hour") + " ")
                + unit(minutes, "minute") + " " + unit(seconds, "second")
        }
    }

    /// A word with a number stuck to its end ("stormfox210", a user name):
    /// Snow Leopard spells the whole thing letter by letter; "stormfox 210" is
    /// a word and a number.  Three letters or more, so "mp3" and "4K" stay.
    private static let wordThenDigits = re(#"(?<![\p{L}\p{N}])(\p{L}{3,})(\p{N}+)(?![\p{L}\p{N}])"#)
    static func separateDigits(_ text: String) -> String {
        replace(wordThenDigits, in: text) { m, ns in group(m, 1, ns) + " " + group(m, 2, ns) }
    }
    private static let capitalWord = re(#"(?<![\p{L}\p{N}])(?=[A-Z]*[AEIOUY])[A-Z]{5,}(?=\p{N}*(?![\p{L}\p{N}]))"#)
    private static let romanOnly = re(#"^[MDCLXVI]+$"#)

    static func capitalsAsWords(_ text: String) -> String {
        replace(capitalWord, in: text) { m, ns in
            let w = group(m, 0, ns)
            if romanOnly.firstMatch(in: w, range: NSRange(location: 0, length: (w as NSString).length)) != nil { return w }
            return w.prefix(1) + w.dropFirst().lowercased()
        }
    }

    static func expandDates(_ text: String) -> String {
        func day(_ s: String) -> String { dayNames[s.lowercased()] ?? s }
        func month(_ s: String) -> String { monthNames[s.lowercased()] ?? s }
        var out = replace(dayAlone, in: text) { m, ns in group(m, 1, ns) + day(group(m, 2, ns)) + group(m, 3, ns) }
        out = replace(dayBeforeDate, in: out) { m, ns in day(group(m, 1, ns)) }
        out = replace(monthBeforeNumber, in: out) { m, ns in month(group(m, 1, ns)) }
        return replace(monthAfterDay, in: out) { m, ns in month(group(m, 1, ns)) }
    }

    /// The engines already spell such strings one character at a time, but
    /// they analyse the whole thing as a single word before making a sound:
    /// an unlabelled lock-screen element read as a 32-character hash took
    /// 274 ms to start on an iPhone, against 30 for its neighbours.  Spaced
    /// out, the audio is the same (Tiger's is identical to the sample) and
    /// it starts several times sooner.
    static func spellIdentifiers(_ text: String) -> String {
        replace(identifier, in: text) { m, ns in group(m, 0, ns).map { String($0) }.joined(separator: " ") }
    }

    /// Emoji arrive as code points from VoiceOver and the engine has no
    /// words for them. Android carries a curated CLDR table (Emoji.kt); until
    /// that is ported, Unicode's own character names say roughly the same.
    /// Text in another script -- a Discord badge in Arabic, a name in
    /// Cyrillic -- is nothing the engines can say: MacRoman made every letter
    /// a space, and VoiceOver seemed to stop in the middle (the owner, Nov 5:
    /// "Offline, Badge, \u{0645}\u{0637}\u{0631}").  A run of such letters, with the
    /// spaces and marks between them, becomes the name of its language
    /// ("Arabic"), or of its script when that is shared and the language is
    /// not clear.
    static func nameForeignText(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isForeignLetter) else { return text }
        var out = ""
        var run = ""
        var gap = ""
        var scriptName: String?
        func flush() {
            guard !run.isEmpty else { return }
            out += " " + foreignName(run) + " "
            run = ""
            scriptName = nil
        }
        for ch in text {
            if let scalar = ch.unicodeScalars.first, isForeignLetter(scalar) {
                let name = scripts.first { $0.0.contains(scalar.value) }?.1 ?? "foreign text"
                if !run.isEmpty && name != scriptName {
                    flush()
                    out += gap
                    gap = ""
                }
                scriptName = name
                run += gap + String(ch)
                gap = ""
            } else if !run.isEmpty && ch.isWhitespace {
                gap += String(ch)
            } else {
                flush()
                out += gap + String(ch)
                gap = ""
            }
        }
        flush()
        return out + gap
    }

    private static func isForeignLetter(_ s: Unicode.Scalar) -> Bool {
        guard s.properties.isAlphabetic else { return false }
        switch s.value {
        case 0x00...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xFF21...0xFF5A: return false   // Latin
        default: return true
        }
    }

    /// Scripts one language owns are named for it; for the shared ones the
    /// recogniser says which language when there is enough to go on, and the
    /// script's name stands in otherwise.
    private static let scripts: [(ClosedRange<UInt32>, String, shared: Bool)] = [
        (0x0600...0x06FF, "Arabic", true), (0x0750...0x077F, "Arabic", true), (0x08A0...0x08FF, "Arabic", true),
        (0xFB50...0xFDFF, "Arabic", true), (0xFE70...0xFEFF, "Arabic", true),
        (0x0590...0x05FF, "Hebrew", false), (0x0370...0x03FF, "Greek", false), (0x1F00...0x1FFF, "Greek", false),
        (0x0400...0x052F, "Cyrillic", true), (0x0530...0x058F, "Armenian", false), (0x10A0...0x10FF, "Georgian", false),
        (0x0900...0x097F, "Devanagari", true), (0x0980...0x09FF, "Bengali", false), (0x0B80...0x0BFF, "Tamil", false),
        (0x0E00...0x0E7F, "Thai", false), (0x1200...0x137F, "Ethiopic", true),
        (0xAC00...0xD7AF, "Korean", false), (0x1100...0x11FF, "Korean", false), (0x3130...0x318F, "Korean", false),
        (0x3040...0x30FF, "Japanese", false), (0x3400...0x4DBF, "Chinese", true), (0x4E00...0x9FFF, "Chinese", true),
    ]

    static func foreignName(_ run: String) -> String {
        let first = run.unicodeScalars.first { isForeignLetter($0) }?.value ?? 0
        let script = scripts.first { $0.0.contains(first) }
        if let script, !script.shared { return script.1 }
        // A few letters cannot tell Arabic from Persian, or Russian from
        // Ukrainian: the recogniser only for ten letters or more.
        guard run.unicodeScalars.filter(isForeignLetter).count >= 10 else { return script?.1 ?? "foreign text" }
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(run)
        if let (language, p) = recogniser.languageHypotheses(withMaximum: 1).first, p >= 0.5,
           let name = Locale(identifier: "en_US").localizedString(forLanguageCode: language.rawValue) {
            return name
        }
        return script?.1 ?? "foreign text"
    }

    static func describeEmoji(_ text: String) -> String {
        var out = ""
        for ch in text {
            let scalars = ch.unicodeScalars
            guard let first = scalars.first,
                  first.properties.isEmojiPresentation
                    || (first.properties.isEmoji && scalars.contains { $0.value == 0xFE0F })
            else { out.append(ch); continue }
            // Keycaps ("1" + U+FE0F + U+20E3) start with the digit itself: keep it.
            if first.value < 0x80 { out.append(ch); continue }
            if (0x1F1E6...0x1F1FF).contains(first.value) { out += " flag "; continue }
            let names = scalars
                .filter { $0.value != 0x200D && $0.value != 0xFE0F && !(0x1F3FB...0x1F3FF).contains($0.value) }
                .compactMap { $0.properties.name?.lowercased() }
            out += names.isEmpty ? " " : " " + names.joined(separator: " ") + " "
        }
        return out
    }

    /// "13:45" -> "13 45", "13:05" -> "13 oh 5", "08:30" -> "oh 8 30", "00:00"
    /// -> "zero zero zero zero": a 24-hour time as Leopard reads it the way
    /// the other generations do (checked on the engines' phonemes: Leopard
    /// reads "13:45" as one forty-five PM and "13 05" as thirteen five).
    /// Only hours 13 to 23 and hours written with a leading zero; "9:05",
    /// "1:45 PM" and times with seconds are left to the engine.
    static let clock = re(#"(?<![\d:.])([01]\d|2[0-3]|\d)\s*:\s*([0-5]\d)(?![\d:])"#)
    public static func twentyFourHour(_ s: String) -> String {
        let ns = s as NSString
        var out = "", at = 0
        func part(_ d: String) -> String {
            if d == "00" { return "zero zero" }
            if d.count == 2 && d.hasPrefix("0") { return "oh " + d.dropFirst() }
            return d
        }
        for m in clock.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let hour = ns.substring(with: m.range(at: 1)), minute = ns.substring(with: m.range(at: 2))
            guard let h = Int(hour), h >= 13 || (hour.count == 2 && hour.hasPrefix("0")) else { continue }
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += part(hour) + " " + part(minute)
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    /// Whether `text` has an embedded command ("[[rate 300]]") in it.
    public static func hasCommand(_ text: String) -> Bool {
        commands.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// Legacy MacinTalk drops these glyphs in ordinary text. Expand only
    /// symbols still present in the request after VoiceOver's own processing.
    static func spokenSymbols(_ text: String, spelling: Bool = false) -> String {
        let names: [Character: String] = ["°": "degrees", "℃": "degrees Celsius",
                                           "℉": "degrees Fahrenheit", "=": "equals"]
        var out = ""
        for character in text {
            if let name = names[character] {
                // Speak the name normally inside a character-reading span,
                // then resume spelling its remaining characters.
                out += spelling ? "[[char NORM]] " + name + " [[char LTRL]]" : " " + name + " "
            } else {
                out.append(character)
            }
        }
        return out
    }

    /// Text -> what the engine hears, commands kept or dropped as configured.
    public static func prepare(_ text: String, settings: PantheraSettings, generation: Generation, spelling: Bool = false) -> String {
        let ns = text as NSString
        var out = ""
        var at = 0
        func plain(_ s: String) -> String {
            let tidied = tidyPunctuation(s)
            let cased = settings.capitalsAsWords ? capitalsAsWords(nameForeignText(tidied)) : nameForeignText(tidied)
            let dated = settings.expandDates ? expandDates(cased) : cased
            let duration = spelling ? dated : expandDurations(dated)
            let numbered = beforeNumbers(duration, generation: generation)
            let timed = settings.twentyFourHour && generation == .leopard ? twentyFourHour(numbered) : numbered
            let prepared = describeEmoji(abbreviations(separateDigits(spellIdentifiers(timed)),
                                                      expand: settings.expandAbbreviations))
            return spokenSymbols(prepared, spelling: spelling)
        }
        for m in commands.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += plain(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            if settings.acceptCommands {
                // Normalise delimiter spacing; never rewrite inside a command.
                let raw = ns.substring(with: m.range)
                let afterSecond = raw.dropFirst().drop { $0 != "[" }.dropFirst()
                let body = afterSecond.prefix { $0 != "]" }
                let command = "[[" + String(body) + "]]"
                let lionInputMode = generation.excludesInputModeCommands
                    && inputMode.firstMatch(in: command, range: NSRange(location: 0, length: (command as NSString).length)) != nil
                if !lionInputMode { out += command }
            }
            at = m.range.location + m.range.length
        }
        out += plain(ns.substring(from: at))
        return out
    }
}
