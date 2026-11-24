import Foundation

/// How the voices speak, as set in the app: switches, each with a default
/// for every voice and overrides per voice (by identifier). Kept as
/// `settings.json` in the extension's store, written by the app over the
/// store's channel and read by the extension on each request.
struct SpeechSettings: Codable, Equatable, Sendable {
    /// Apple's text rules (PronunciationRules): the ones the voice's own iOS
    /// release or Mac OS X voice had.
    var rules = true
    /// Apple's later pronunciation dictionary and rules (a VoiceResources
    /// pack per language, see PronunciationPacks), loaded into the engine on
    /// top of the voice's own. Off: each voice speaks as its release did.
    var newerRules = false
    /// Pitch changes speak with the voice's compact version, as the original
    /// VoiceOver did: enhanced and premium voices can't change pitch themselves.
    var pitchFallback = true
    /// MacinTalk: embedded speech commands ([[inpt PHON]], [[rate 300]] ...)
    /// last only for the utterance they are in, instead of until changed back.
    var resetCommands = true
    /// MacinTalk: Leopard reads 24-hour times as Snow Leopard does (13:45 is
    /// "thirteen forty-five", not "one forty-five PM").
    var twentyFourHour = true
    /// MacinTalk: a rate speaks at the words per minute today's Alex speaks
    /// at, instead of a percent of the voice's own default rate.
    var modernRate = true
    /// The voices shorten a pause the faster they speak: on, a pause VoiceOver
    /// or an app asks for lasts as long at any rate (vxs_set_steady_pauses).
    var steadyPauses = true
    /// Spelling pauses before, between and after the letters, as the voices
    /// themselves do (vxs_set_spelling_pauses). iOS 3 and 4 voices always do.
    var spellingPauses = false
    /// Spelled capitals said as lowercase letters, without "capital" before them (vxs_set_spell_lowercase).
    var spellLowercase = false
    /// The community pronunciation dictionaries (CommunityDictionary): opt in. Off, nothing is fetched.
    var communityDictionaries = false
    var rulesOverride: [String: Bool] = [:]
    var newerRulesOverride: [String: Bool] = [:]
    var pitchFallbackOverride: [String: Bool] = [:]
    var resetCommandsOverride: [String: Bool] = [:]
    /// Panthera behavior is confined to the four MacinTalk generations.
    /// Vocalizer retains its existing settings and pronunciation path.
    var macinTalkCompatibility = true
    var macinTalk: [String: PantheraSettings] = [:]
    var macinTalkInflectionOverride: [String: Int] = [:]
    var macinTalkPronunciations: [Pronunciation] = []
    var logSpokenText = false

    func macinTalkSettings(_ generation: Generation, voiceKey: String? = nil) -> PantheraSettings {
        var profile = macinTalk[generation.rawValue] ?? PantheraSettings.defaults(for: generation)
        if let voiceKey {
            let defaultInflection: Int? = voiceKey == "mt107/Alex-sequoia" ? 140 : nil
            if let value = macinTalkInflectionOverride[voiceKey] ?? defaultInflection {
                profile.inflection = min(200, max(0, value))
            }
        }
        return profile
    }

    static let file = "settings.json"

    func rulesEnabled(_ voiceID: String) -> Bool { rulesOverride[voiceID] ?? rules }
    func newerRulesEnabled(_ voiceID: String) -> Bool { newerRulesOverride[voiceID] ?? newerRules }
    /// Whether any voice has the newer rules on, so their packs are needed.
    var newerRulesWanted: Bool { newerRules || newerRulesOverride.values.contains(true) }
    func pitchFallbackEnabled(_ voiceID: String) -> Bool { pitchFallbackOverride[voiceID] ?? pitchFallback }
    func resetCommandsEnabled(_ voiceID: String) -> Bool { resetCommandsOverride[voiceID] ?? resetCommands }

    init() {}
    // Settings saved before a switch existed keep the others, and the new one starts at its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent(Bool.self, forKey: .rules) ?? rules
        newerRules = try c.decodeIfPresent(Bool.self, forKey: .newerRules) ?? newerRules
        pitchFallback = try c.decodeIfPresent(Bool.self, forKey: .pitchFallback) ?? pitchFallback
        resetCommands = try c.decodeIfPresent(Bool.self, forKey: .resetCommands) ?? resetCommands
        twentyFourHour = try c.decodeIfPresent(Bool.self, forKey: .twentyFourHour) ?? twentyFourHour
        modernRate = try c.decodeIfPresent(Bool.self, forKey: .modernRate) ?? modernRate
        steadyPauses = try c.decodeIfPresent(Bool.self, forKey: .steadyPauses) ?? steadyPauses
        spellingPauses = try c.decodeIfPresent(Bool.self, forKey: .spellingPauses) ?? spellingPauses
        spellLowercase = try c.decodeIfPresent(Bool.self, forKey: .spellLowercase) ?? spellLowercase
        communityDictionaries = try c.decodeIfPresent(Bool.self, forKey: .communityDictionaries) ?? communityDictionaries
        rulesOverride = try c.decodeIfPresent([String: Bool].self, forKey: .rulesOverride) ?? [:]
        newerRulesOverride = try c.decodeIfPresent([String: Bool].self, forKey: .newerRulesOverride) ?? [:]
        pitchFallbackOverride = try c.decodeIfPresent([String: Bool].self, forKey: .pitchFallbackOverride) ?? [:]
        resetCommandsOverride = try c.decodeIfPresent([String: Bool].self, forKey: .resetCommandsOverride) ?? [:]
        macinTalkCompatibility = try c.decodeIfPresent(Bool.self, forKey: .macinTalkCompatibility) ?? true
        macinTalk = try c.decodeIfPresent([String: PantheraSettings].self, forKey: .macinTalk) ?? [:]
#if CV_IOS10_ALEX
        // A partial iOS profile must use its generation's default too. Preserve
        // every explicitly saved value, including a deliberate choice of 100.
        if macinTalk[Generation.ios10Alex.rawValue] != nil {
            struct InflectionField: Decodable { var inflection: Int? }
            let fields = try c.decode([String: InflectionField].self, forKey: .macinTalk)
            if fields[Generation.ios10Alex.rawValue]?.inflection == nil {
                macinTalk[Generation.ios10Alex.rawValue]?.inflection = Generation.ios10Alex.defaultInflection
            }
        }
#endif
        macinTalkInflectionOverride = try c.decodeIfPresent([String: Int].self, forKey: .macinTalkInflectionOverride) ?? [:]
        macinTalkPronunciations = try c.decodeIfPresent([Pronunciation].self, forKey: .macinTalkPronunciations) ?? []
        logSpokenText = try c.decodeIfPresent(Bool.self, forKey: .logSpokenText) ?? false
    }

    static func decode(_ data: Data) -> SpeechSettings? { try? JSONDecoder().decode(SpeechSettings.self, from: data) }
    func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    // MARK: - the extension's copy

    nonisolated(unsafe) private static var cached = SpeechSettings()
    private struct FileStamp: Equatable {
        var date: Date?
        var size: UInt64?
        var inode: UInt64?
    }
    nonisolated(unsafe) private static var cachedStamp: FileStamp?
    private static let lock = NSLock()

    /// Settings as stored in this process's voice root (the extension's
    /// store, or the App Group for a process without one), re-read when the
    /// file changes.
    static var current: SpeechSettings {
        lock.lock(); defer { lock.unlock() }
        guard let url = VoiceCatalog.enhancedRoot?.appendingPathComponent(file) else { return cached }
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        let stamp = FileStamp(date: attributes?[.modificationDate] as? Date,
                              size: (attributes?[.size] as? NSNumber)?.uint64Value,
                              inode: (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value)
        if stamp != cachedStamp {
            if let data = try? Data(contentsOf: resolved), let decoded = decode(data) {
                cached = decoded
                cachedStamp = stamp
            } else if attributes == nil {
                // A local packed install can supply defaults with its voice
                // data. User changes in the extension store take precedence.
                if let root = VoiceCatalog.root, root.standardizedFileURL != url.deletingLastPathComponent().standardizedFileURL,
                   let data = try? Data(contentsOf: root.appendingPathComponent(file)), let packed = decode(data) {
                    cached = packed
                    cached.logSpokenText = false
                } else { cached = SpeechSettings() }
                cachedStamp = stamp
            }
            // Keep the last valid settings if a damaged or unreadable file
            // is encountered, and retry it on the next request.
        }
        return cached
    }
}
