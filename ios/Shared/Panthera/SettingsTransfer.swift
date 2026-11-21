import Foundation

enum PantheraSettingsTransfer {
    private struct Export: Codable {
        let format: String
        let version: Int
        let settings: SpeechSettings
    }
    enum ImportError: LocalizedError {
        case invalid, unsupportedVersion
        var errorDescription: String? {
            switch self {
            case .invalid: return "Choose a Panthera settings property list or a Classic Voices settings export."
            case .unsupportedVersion: return "This settings export uses a newer format."
            }
        }
    }
    static func exported(_ settings: SpeechSettings) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(format: "classicvoices-panthera-settings", version: 1, settings: settings))
    }
    static func imported(_ data: Data, preserving current: SpeechSettings) throws -> SpeechSettings {
        if let envelope = try? JSONDecoder().decode(Export.self, from: data) {
            guard envelope.format == "classicvoices-panthera-settings" else { throw ImportError.invalid }
            guard envelope.version == 1 else { throw ImportError.unsupportedVersion }
            var settings = envelope.settings
            settings.logSpokenText = false
            return settings
        }
        return try importPropertyList(data, preserving: current)
    }
    private static let prefixes = ["volume", "rate_wpm", "number_style", "accept_commands", "reset_commands",
        "twenty_four_hour", "expand_abbreviations", "expand_dates", "capitals_as_words", "phrasing",
        "rate_boost", "natural_pauses", "quick_interrupt", "inflection", "mac_pauses"]
    private static func importPropertyList(_ data: Data, preserving current: SpeechSettings) throws -> SpeechSettings {
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.invalid
        }
        return try importValues(values, preserving: current)
    }
    private static func importValues(_ values: [String: Any], preserving current: SpeechSettings) throws -> SpeechSettings {
        let keys = Set(Generation.allCases.flatMap { generation in prefixes.map { "\($0)_\(generation.rawValue)" } })
        guard values.keys.contains(where: { keys.contains($0) || $0 == Pronunciations.key }) else { throw ImportError.invalid }
        let suite = "classicvoices.settings-import.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: values.filter { keys.contains($0.key) })
        var settings = current
        for generation in Generation.allCases where prefixes.contains(where: { values["\($0)_\(generation.rawValue)"] != nil }) {
            settings.macinTalk[generation.rawValue] = PantheraSettings.load(generation, from: defaults)
        }
        if let value = values[Pronunciations.key] {
            guard let encoded = value as? Data else { throw ImportError.invalid }
            settings.macinTalkPronunciations = try JSONDecoder().decode([Pronunciation].self, from: encoded)
        }
        settings.macinTalkCompatibility = true
        settings.logSpokenText = false
        return settings
    }
}
