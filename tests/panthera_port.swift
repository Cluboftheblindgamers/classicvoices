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
#if CV_IOS10_ALEX
        require(settings.macinTalkSettings(.ios10Alex).inflection == 140, "iOS Alex engine default inflection")
        let partialIOS = SpeechSettings.decode(Data(#"{"macinTalk":{"ios10Alex":{"rate":220}}}"#.utf8))!
        require(partialIOS.macinTalkSettings(.ios10Alex).inflection == 140, "partial iOS profile keeps engine default")
        let explicitIOS = SpeechSettings.decode(Data(#"{"macinTalk":{"ios10Alex":{"inflection":100}}}"#.utf8))!
        require(explicitIOS.macinTalkSettings(.ios10Alex).inflection == 100, "explicit iOS inflection remains adjustable")
        require(SpeechSettings.decode(partialIOS.encoded())!.macinTalkSettings(.ios10Alex).inflection == 140, "iOS default roundtrip")
        let safariXML = "<speak><prosody rate='219.99998%'>Safari <break time='60ms'/> (4 of 24)</prosody></speak>"
        let safariJob = SpeechJob.from(ssml: safariXML, voiceKey: "mtios10/Alex", settings: settings)
        require(safariJob.text == "Safari [[slnc 60]] (4 of 24)", "captured Safari keeps text and requested break")
        require(safariJob.macinTalkWPM == 396, "captured Safari rate remains intact")
        let dockXML = "<speak><prosody rate='219.99998%'>Dock<break time='500ms'/>  </prosody></speak>"
        let dockJob = SpeechJob.from(ssml: dockXML, voiceKey: "mtios10/Alex", settings: settings)
        require(dockJob.text == "Dock[[slnc 500]] " && dockJob.trailingPauseMs == 0,
                "iOS Alex preview final break reaches engine without duplicate host silence")
        require(dockJob.macinTalkPitchTenths == 0 && dockJob.pitch == 100 && dockJob.macinTalkWPM == 396,
                "final-pause experiment leaves pitch and rate unchanged")
        let bareIOS = SpeechJob.from(ssml: "<speak>Dock</speak>", voiceKey: "mtios10/Alex", settings: settings)
        require(bareIOS.text == "Dock" && bareIOS.trailingPauseMs == 0, "bare iOS word unchanged")
        require(MacinTalkProvider.cacheKey(dockJob, voiceKey: "mtios10/Alex", settings: settings)
            != MacinTalkProvider.cacheKey(bareIOS, voiceKey: "mtios10/Alex", settings: settings), "new final-pause audio has a distinct cache key")
        let pauseIOS = SpeechJob.from(ssml: "<speak><break time='500ms'/></speak>", voiceKey: "mtios10/Alex", settings: settings)
        require(pauseIOS.text.isEmpty && pauseIOS.trailingPauseMs == 500, "iOS silence-only request survives")
        var noPausesIOS = settings
        var iosProfile = settings.macinTalkSettings(.ios10Alex)
        iosProfile.macPauses = false; noPausesIOS.macinTalk["ios10Alex"] = iosProfile
        let disabledIOS = SpeechJob.from(ssml: dockXML, voiceKey: "mtios10/Alex", settings: noPausesIOS)
        require(disabledIOS.text == "Dock" && disabledIOS.trailingPauseMs == 0, "iOS Mac pauses control opts out")
        let oldDock = SpeechJob.from(ssml: dockXML, voiceKey: "mt106/Alex", settings: settings)
        require(oldDock.trailingPauseMs == 0, "older Mac navigation trailing-pause behavior unchanged")
        for ms in [60, 276, 300] {
            let job = SpeechJob.from(ssml: "<speak>Safari<break time='\(ms)ms'/>Dock item</speak>", voiceKey: "mtios10/Alex", settings: settings)
            require(job.text == "Safari [[slnc \(ms)]] Dock item", "iOS break preserved without quotes")
        }

#endif
        // Headings become words, while abbreviations, Roman numerals and
        // literal spelling keep their distinct meanings on every generation.
        for generation in Generation.allCases {
            var profile = PantheraSettings()
            require(SpeechText.prepare("FACETIME SETTINGS JANESMITH4 HTTPS MCMXCIV", settings: profile, generation: generation, spelling: false)
                .contains("Facetime Settings Janesmith 4 HTTPS MCMXCIV"), "expanded capitalization and exceptions")
            profile.capitalsAsWords = false
            require(SpeechText.prepare("FACETIME", settings: profile, generation: generation, spelling: false) == "FACETIME", "capitalization control off")
            profile.expandDates = true
            require(SpeechText.prepare("SAT OCT 23", settings: profile, generation: generation) == "Saturday October 23", "date headings on every generation")
            profile.expandDates = false
            require(SpeechText.prepare("Sat Oct 23", settings: profile, generation: generation) == "Sat Oct 23", "date expansion opt-out")
            profile.twentyFourHour = true
            let clock = "13:05, 08:30, 00:00; 9:05 and 1:45 PM"
            let expectedClock = generation == .leopard ? "13 oh 5, oh 8 30, zero zero zero zero; 9:05 and 1:45 PM" : clock
            require(SpeechText.prepare(clock, settings: profile, generation: generation) == expectedClock, "24-hour correction targets Leopard and preserves ordinary times")
            profile.twentyFourHour = false
            require(SpeechText.prepare(clock, settings: profile, generation: generation) == clock, "24-hour opt-out preserves engine input")
        }
        for value in ["1e308", "NaN", "Infinity", "-1e308", "1e308%"] {
            let xml = "<speak><mark name='start'/><prosody rate='\(value)' volume='\(value)' pitch='\(value)'>window<break time='\(value)s'/></prosody></speak>"
            for voice in ["mt106/Alex", "ios6/en-US"] {
                let bounded = SpeechJob.from(ssml: xml, voiceKey: voice, settings: settings)
                require((0...10_000).contains(bounded.rate) && (0...60_000).contains(bounded.trailingPauseMs), "extreme rich SSML is bounded")
            }
        }
        let repeatedPitch = String(repeating: "<prosody pitch='10000'>", count: 12) + "window" + String(repeating: "</prosody>", count: 12)
        require(SpeechJob.from(ssml: "<speak><mark name='x'/>\(repeatedPitch)</speak>", voiceKey: "ios6/en-US", settings: settings).pitch <= 1_000_000, "nested pitch cannot overflow")
        require(SpeechText.expandDates("SAT OCT 23") == "Saturday October 23", "uppercase Saturday expands with other date headings")
        let quietRich = SpeechJob.from(ssml: "<speak><prosody volume='-6dB'><mark name='x'/>window</prosody></speak>", voiceKey: "mt106/Alex", settings: settings)
        require(abs(quietRich.macinTalkGain - 0.5) < 0.02, "rich SSML dB volume reaches MacinTalk output gain")
        let quietVocalizer = SpeechJob.from(ssml: "<speak><prosody volume='-6dB'>window</prosody></speak>", voiceKey: "ios6/en-US", settings: settings)
        require(quietVocalizer.volume == 40, "Vocalizer dB volume is honored")
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
