import Foundation
@testable import ClassicPortTest

@main struct PantheraPortCheck {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    static func main() throws {
        var settings = SpeechSettings()
        require(settings.macinTalkCompatibility && !settings.logSpokenText, "safe compatibility defaults")
        require(settings.macinTalkSettings(.snowleopard).inflection == 100, "VoiceOver inflection")
        let key = "mt106/Alex"
        func prepare(_ text: String) -> String { MacinTalkCompatibility.prepare(text, voiceKey: key, settings: settings) }
        require(prepare("Read 10:38 PM") == "Red 10:38 PM", "receipt")
        require(prepare("Read aloud") == "Read aloud", "imperative read")
        require(prepare("Read 3 chapters") == "Read 3 chapters", "numeric instruction")
        require(prepare("1 minute 9 seconds") == "1 minnitt 9 seconds", "duration minute")
        require(prepare("A minute detail") == "A minute detail", "adjective minute")
        require(prepare("1 m 26 s") == "1 minnitt 26 seconds", "compact duration")
        require(prepare("1 m") == "1 m", "ambiguous units")
        require(prepare("23°").contains("degrees"), "degrees")
        require(prepare("2 = 2").contains("equals"), "equals")
        require(prepare("\u{0141}ukasz").contains("Lukasz"), "MacRoman fold")
        require(prepare("مطر").contains("Arabic"), "foreign script is audible")
        let hash = "711495d10bb643f6b236c91a09edee65"
        require(prepare(hash).contains("7 1 1 4"), "identifier latency correction")
        require(!prepare("[[pmod 0]]window").contains("[["), "typed commands default off")
        require(!prepare("window" + SSMLRequest.pauseMark(60)).contains("[[slnc"), "literal text cannot inject internal controls")
        var profile = PantheraSettings(); profile.acceptCommands = true
        settings.macinTalk["snowleopard"] = profile
        require(prepare("[[pmod 0]]window").contains("[[pmod 0]]"), "typed commands opt in")
        require(prepare("[[pmod 0]]window").contains("[[rset 0]]"), "command reset")
        settings.macinTalk = [:]

        var entry = Pronunciation(match: "pineapple", replacement: "banana")
        entry.voiceIDs = ["com.pantheraspeech.snowleopard.alex"]
        settings.macinTalkPronunciations = [entry]
        require(prepare("pineapple") == "banana", "exact voice scope")
        require(MacinTalkCompatibility.prepare("pineapple", voiceKey: "mt106/Fred", settings: settings) == "pineapple", "other voice unchanged")
        entry.voiceIDs = []; settings.macinTalkPronunciations = [entry]
        require(prepare("pineapple") == "pineapple", "empty voice selection applies nowhere")
        entry.voiceIDs = nil; entry.generations = [.leopard]; settings.macinTalkPronunciations = [entry]
        require(prepare("pineapple") == "pineapple", "generation scope")
        require(MacinTalkCompatibility.prepare("pineapple", voiceKey: "mt105/Alex", settings: settings) == "banana", "selected generation")
        let untouched = "Read 10:38 PM, 1 minute 9 seconds, 23°, [[rate 300]]"
        require(MacinTalkCompatibility.prepare(untouched, voiceKey: "ios6/en-US", settings: settings) == untouched, "Vocalizer bypass")
        settings.macinTalkPronunciations = []

        let role = SpeechJob.from(ssml: "<speak>TextEdit<break time='300ms'/>window</speak>", voiceKey: key, settings: settings)
        require(role.text.contains("[[slnc 300]]") && role.text.contains(", window"), "long-pause role intonation")
        require(role.macinTalkWPM == 180, "absolute rate")
        let exactPitch = SpeechJob.from(ssml: "<speak><prosody pitch='+9st'>window</prosody></speak>", voiceKey: key, settings: settings)
        require(exactPitch.macinTalkPitchTenths == 90, "exact semitone pitch")
        let receipt = SpeechJob.from(ssml: "<speak>\u{200E}Read 10:38\u{202F}PM</speak>", voiceKey: key, settings: settings)
        require(receipt.text.contains("Red 10:38"), "real receipt Unicode")
        let joined = SpeechJob.from(ssml: "<speak><voice>In</voice><voice>list view</voice></speak>", voiceKey: key, settings: settings)
        require(joined.text == "In list view", "Classic voice boundary retained")
        let pause = SpeechJob.from(ssml: "<speak><break time='680ms'/></speak>", voiceKey: key, settings: settings)
        require(pause.text.isEmpty && pause.trailingPauseMs == 680, "pause only")
        let quiet = SpeechJob.from(ssml: "<speak><prosody volume='-6.0206dB'>window</prosody></speak>", voiceKey: key, settings: settings)
        require(abs(quiet.macinTalkGain - 0.5) < 0.0001, "volume gain")
        let bookmark = SpeechJob.from(ssml: "<speak>one<mark name='here'/>two</speak>", voiceKey: key, settings: settings)
        require(bookmark.markNames == ["here"] && bookmark.text.contains("\\mrk=0\\"), "Classic bookmarks retained")
        let nested = SpeechJob.from(ssml: "<speak>one <prosody rate='150%'>two</prosody> three</speak>", voiceKey: key, settings: settings)
        require(nested.text.contains("\\rate=150\\"), "nested rate retained")
        let sentence = SpeechJob.from(ssml: "<speak><s>one</s><s>two</s></speak>", voiceKey: key, settings: settings)
        require(sentence.text.contains("\\eos=1\\"), "sentence boundaries retained")
        let xml = "<speak><prosody rate='120%' pitch='+20%'>Read 10:38 PM</prosody></speak>"
        let oldVocalizer = SpeechJob.from(ssml: xml)
        let newVocalizer = SpeechJob.from(ssml: xml, voiceKey: "ios6/en-US", settings: settings)
        require(oldVocalizer.text == newVocalizer.text && oldVocalizer.rate == newVocalizer.rate && oldVocalizer.pitch == newVocalizer.pitch, "Vocalizer parser parity")

        require(mte_numbers_check() == 0, "number corpus")
        require(mte_volume_milli(90, "snowleopard", "Alex") == 1460, "Alex normalization")
        require(mte_volume_milli(90, "lion", "Alex") == 1190, "Lion normalization")
        require(mte_volume_milli(100, "tiger", "Fred") == 1000, "Tiger normalization")
        var numberProfile = PantheraSettings(); numberProfile.numbers = .words
        settings.macinTalk["snowleopard"] = numberProfile
        require(prepare("3222233").contains("million"), "number words through actual port")
        settings.macinTalk = [:]
        let partial = try JSONDecoder().decode(PantheraSettings.self, from: Data(#"{"inflection":140}"#.utf8))
        require(partial.inflection == 140 && partial.naturalPauses, "partial settings decode")
        let old = try JSONDecoder().decode(SpeechSettings.self, from: Data(#"{"rules":false}"#.utf8))
        require(!old.rules && old.macinTalkCompatibility && !old.logSpokenText, "legacy Classic settings preserved")

        settings.newerRules = true
        settings.logSpokenText = true
        let plist: [String: Any] = ["inflection_snowleopard": 140, "rate_wpm_snowleopard": 220,
                                   "pronunciations": try JSONEncoder().encode([entry]), "log_spoken_text": true]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let imported = try PantheraSettingsTransfer.imported(data, preserving: settings)
        require(imported.newerRules && !imported.logSpokenText, "migration preserves Vocalizer and keeps logging off")
        require(imported.macinTalkSettings(.snowleopard).inflection == 140 && imported.macinTalkSettings(.snowleopard).rate == 220, "Panthera settings migration")
        require(imported.macinTalkPronunciations == [entry], "scope migration")
        let roundtrip = try PantheraSettingsTransfer.imported(PantheraSettingsTransfer.exported(imported), preserving: SpeechSettings())
        require(roundtrip == imported, "Classic export round trip")
        do {
            _ = try PantheraSettingsTransfer.imported(Data("{}".utf8), preserving: settings)
            preconditionFailure("unrecognized settings accepted")
        } catch {}
        print("PASS \(checks) Panthera integration checks")
    }
}
