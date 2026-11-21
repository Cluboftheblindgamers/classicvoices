// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation

/// Per-generation settings, in the shared App Group defaults so the app writes
/// them and the extension reads them on every utterance. Same names and
/// ranges as Android's PantheraEngine.Settings; the defaults for numbers and
/// phrase breaks differ (Oct 23: the engine's own, as on the Mac).
public struct PantheraSettings: Codable, Equatable, Sendable {
    public enum NumberStyle: String, Codable, CaseIterable, Sendable { case fix, words, off }
    public enum Phrasing: String, Codable, CaseIterable, Sendable { case fewest, fewer, more, most, leopard }

    /// NVDA scale 0...100, or -1 for the generation's measured default.
    public var volume: Int = -1
    /// Words per minute; 0 follows the rate VoiceOver or the app asks for.
    public var rate: Int = 0
    /// Off by default: the engine reads numbers itself, as on the Mac.  "fix"
    /// grouped every run of seven or more digits, which made a phone number
    /// written without dashes ("5551234567") "five billion five hundred...",
    /// where the engine on its own reads it digit by digit.
    public var numbers: NumberStyle = .off
    public var acceptCommands: Bool = false
    /// With embedded commands accepted: what a command changes ("[[inpt
    /// PHON]]", "[[char LTRL]]", "[[pmod 0]]") lasts until the end of the
    /// announcement it came in.  The engine keeps it on the channel for every
    /// utterance after (measured on all four generations: the next utterance
    /// changed); "[[rset 0]]" after the text puts it back, and the next
    /// utterance then sounds exactly as without the command.
    public var resetCommands: Bool = true
    /// Leopard only: 24-hour times ("13:45", "08:30") read as Tiger, Snow
    /// Leopard and Lion read them -- "thirteen forty five" -- rather than as
    /// Leopard does, "one forty five PM".  Off by default, as Leopard sounded
    /// on the Mac.  SpeechText.twentyFourHour.
    public var twentyFourHour: Bool = false
    public var expandAbbreviations: Bool = true
    /// Short day and month names in dates ("Fri Oct 23", "Fri 9:32 AM") read
    /// in full, as Lion does.  Off by default: Tiger to Snow Leopard expand
    /// them only with a period or comma after ("Fri." is Friday, bare "Fri"
    /// is "free" on Snow Leopard and "fry" on Leopard), and that is how they
    /// sounded on the Mac.  SpeechText.expandDates.
    public var expandDates: Bool = false
    /// Words in capitals read as words: "FACETIME" as FaceTime, not
    /// F-A-C-E-T-I-M-E.  Leopard and Snow Leopard spell out a word in
    /// capitals they have no entry for, and today's interfaces show many
    /// headings and labels in capitals that were written in ordinary case
    /// (the text VoiceOver hands over is the capitals).  Words of five letters
    /// or more, with a vowel, become Title case first; the engines read words
    /// they know the same either way, and still spell what they cannot say
    /// ("HTTPS").  SpeechText.capitalsAsWords.
    public var capitalsAsWords: Bool = true
    /// Applied when the engine opens; the host caches it for the process.
    /// `.leopard` is the engine's own setting ("As Lion shipped" in the
    /// app): the default, because "fewest" took out the phrase breaks Snow
    /// Leopard and Lion make on their own ("...carefully, before you begin").
    public var phrasing: Phrasing = .leopard
    /// Rate boost: VoiceOver's rates above normal go faster still (the
    /// multiplier is squared, so "twice normal" becomes four times), and the
    /// top of the range rises from 500 to 1200 wpm.  Normal and slower rates
    /// are unchanged.
    public var rateBoost: Bool = false
    /// VoiceOver's short pauses between the parts of an announcement become
    /// phrase breaks inside one utterance (SSMLRequest.joined), as with
    /// Apple's voices; off speaks each part separately with the exact pause.
    public var naturalPauses: Bool = true
    /// Quick interruptions: long announcements go to the engine a clause at a
    /// time (cut at commas and sentence ends, SSMLRequest.split), because a
    /// swipe has to wait for the engine to finish the piece it is rendering.
    /// Interruptions come sooner -- most on Lion and Snow Leopard, whose
    /// unfamiliar names are slow -- at the cost of a slightly different
    /// sound where a clause ends, and of Alex's breaths between sentences.
    /// Off: each announcement is one utterance, as the engine reads it on
    /// the Mac.
    public var quickInterrupt: Bool = false
    /// Inflection: the pitch modulation every utterance is spoken with, how
    /// far the pitch rises and falls (0 none).  100 by default, what VoiceOver
    /// on Snow Leopard set for every voice (traced, Nov 5): Alex's own is
    /// 140, so in VoiceOver he moved less than in `say`; Fred's and Victoria's
    /// own are 100.  A slider rather than an on/off, at the owner's
    /// suggestion.
    public var inflection: Int = 100
    public static let inflectionRange = 0...200
    /// VoiceOver's short pauses as a silence before the comma, as VoiceOver
    /// on Mac OS X wrote them ("Finder [[slnc 60]] , running"), at most 60 ms:
    /// iOS asks 276 ms, and the silence on top of the comma made every pause
    /// longer (the owner, Nov 5).  Off: a comma alone.
    public var macPauses: Bool = true

    public static let rateFloor = 80
    public static let rateCeiling = 500
    public static let rateCeilingBoost = 1200
    /// The engine's own normal rate, and what "100%" means.
    public static let normalRate = 180

    public init() {}

    private enum CodingKeys: String, CodingKey { case volume, rate, numbers, acceptCommands, resetCommands, twentyFourHour, expandAbbreviations, expandDates, capitalsAsWords, phrasing, rateBoost, naturalPauses, quickInterrupt, inflection, macPauses }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        volume = try values.decodeIfPresent(Int.self, forKey: .volume) ?? volume
        rate = try values.decodeIfPresent(Int.self, forKey: .rate) ?? rate
        numbers = try values.decodeIfPresent(NumberStyle.self, forKey: .numbers) ?? numbers
        acceptCommands = try values.decodeIfPresent(Bool.self, forKey: .acceptCommands) ?? acceptCommands
        resetCommands = try values.decodeIfPresent(Bool.self, forKey: .resetCommands) ?? resetCommands
        twentyFourHour = try values.decodeIfPresent(Bool.self, forKey: .twentyFourHour) ?? twentyFourHour
        expandAbbreviations = try values.decodeIfPresent(Bool.self, forKey: .expandAbbreviations) ?? expandAbbreviations
        expandDates = try values.decodeIfPresent(Bool.self, forKey: .expandDates) ?? expandDates
        capitalsAsWords = try values.decodeIfPresent(Bool.self, forKey: .capitalsAsWords) ?? capitalsAsWords
        phrasing = try values.decodeIfPresent(Phrasing.self, forKey: .phrasing) ?? phrasing
        rateBoost = try values.decodeIfPresent(Bool.self, forKey: .rateBoost) ?? rateBoost
        naturalPauses = try values.decodeIfPresent(Bool.self, forKey: .naturalPauses) ?? naturalPauses
        quickInterrupt = try values.decodeIfPresent(Bool.self, forKey: .quickInterrupt) ?? quickInterrupt
        inflection = try values.decodeIfPresent(Int.self, forKey: .inflection) ?? inflection
        macPauses = try values.decodeIfPresent(Bool.self, forKey: .macPauses) ?? macPauses
        volume = min(max(volume, -1), 100)
        rate = min(max(rate, 0), rateLimit)
        inflection = min(max(inflection, 0), 200)
    }


    public var rateLimit: Int { rateBoost ? Self.rateCeilingBoost : Self.rateCeiling }

    public func engineVolume(_ gen: Generation) -> Int { volume < 0 ? gen.defaultVolume : volume }

    /// A fixed rate set here wins; otherwise the caller's multiplier of the
    /// normal rate, clamped either way -- both ways in, as on Android.
    public func wpm(requestMultiplier: Double) -> Int {
        var m = requestMultiplier.isFinite ? max(requestMultiplier, 0.01) : 1
        if rateBoost && m > 1 { m *= m }
        let wanted = rate > 0 ? Double(rate) : Double(Self.normalRate) * m
        return Int(min(max(wanted.rounded(), Double(Self.rateFloor)), Double(rateLimit)))
    }

    // MARK: - Storage

    private static func key(_ name: String, _ gen: Generation) -> String { "\(name)_\(gen.rawValue)" }

    public static func load(_ gen: Generation, from defaults: UserDefaults = AppGroup.defaults) -> PantheraSettings {
        var s = PantheraSettings()
        func value(_ name: String) -> Any? { defaults.object(forKey: key(name, gen)) }
        if let v = value("volume") as? Int { s.volume = min(max(v, -1), 100) }
        if let v = value("rate_wpm") as? Int { s.rate = max(v, 0) }
        if let v = value("number_style") as? String, let n = NumberStyle(rawValue: v) { s.numbers = n }
        if let v = value("accept_commands") as? Bool { s.acceptCommands = v }
        if let v = value("reset_commands") as? Bool { s.resetCommands = v }
        if let v = value("twenty_four_hour") as? Bool { s.twentyFourHour = v }
        if let v = value("expand_abbreviations") as? Bool { s.expandAbbreviations = v }
        if let v = value("expand_dates") as? Bool { s.expandDates = v }
        if let v = value("capitals_as_words") as? Bool { s.capitalsAsWords = v }
        if let v = value("phrasing") as? String, let p = Phrasing(rawValue: v) { s.phrasing = p }
        if let v = value("rate_boost") as? Bool { s.rateBoost = v }
        if let v = value("natural_pauses") as? Bool { s.naturalPauses = v }
        if let v = value("quick_interrupt") as? Bool { s.quickInterrupt = v }
        if let v = value("inflection") as? Int { s.inflection = min(max(v, inflectionRange.lowerBound), inflectionRange.upperBound) }
        if let v = value("mac_pauses") as? Bool { s.macPauses = v }
        s.rate = min(s.rate, s.rateLimit)
        return s
    }

    public func save(_ gen: Generation, to defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(volume, forKey: Self.key("volume", gen))
        defaults.set(rate, forKey: Self.key("rate_wpm", gen))
        defaults.set(numbers.rawValue, forKey: Self.key("number_style", gen))
        defaults.set(acceptCommands, forKey: Self.key("accept_commands", gen))
        defaults.set(resetCommands, forKey: Self.key("reset_commands", gen))
        defaults.set(twentyFourHour, forKey: Self.key("twenty_four_hour", gen))
        defaults.set(expandAbbreviations, forKey: Self.key("expand_abbreviations", gen))
        defaults.set(expandDates, forKey: Self.key("expand_dates", gen))
        defaults.set(capitalsAsWords, forKey: Self.key("capitals_as_words", gen))
        defaults.set(phrasing.rawValue, forKey: Self.key("phrasing", gen))
        defaults.set(rateBoost, forKey: Self.key("rate_boost", gen))
        defaults.set(naturalPauses, forKey: Self.key("natural_pauses", gen))
        defaults.set(quickInterrupt, forKey: Self.key("quick_interrupt", gen))
        defaults.set(inflection, forKey: Self.key("inflection", gen))
        defaults.set(macPauses, forKey: Self.key("mac_pauses", gen))
    }

    // MARK: - App-wide

    /// The timing line in the system log carries what was spoken only when
    /// this is on: everything VoiceOver reads -- messages, mail -- would
    /// otherwise sit in a log any connected Mac or sysdiagnose can read.
    public static let logTextKey = "log_spoken_text"
    public static var logSpokenText: Bool {
        get {
            // A public build logs nothing of what is spoken, whatever is stored.
            #if PANTHERA_PUBLIC
            return false
            #else
            return AppGroup.defaults.bool(forKey: logTextKey)
            #endif
        }
        set { AppGroup.defaults.set(newValue, forKey: logTextKey) }
    }
}
