import Foundation
@testable import ClassicPortTest

@main struct LionPronunciationCheck {
    static func main() throws {
        let key = "mt107/Alex"
        var settings = SpeechSettings()
        func prepare(_ text: String) -> String {
            MacinTalkCompatibility.prepare(text, voiceKey: key, settings: settings)
        }
        precondition(settings.macinTalkSettings(.lion).inflection == 100)
        let newerKey = "mt107/Alex-sequoia"
        precondition(settings.macinTalkSettings(.lion, voiceKey: newerKey).inflection == 140)
        var custom = settings
        custom.macinTalk[Generation.lion.rawValue] = PantheraSettings()
        custom.macinTalk[Generation.lion.rawValue]!.inflection = 85
        precondition(custom.macinTalkSettings(.lion, voiceKey: key).inflection == 85)
        precondition(custom.macinTalkSettings(.lion, voiceKey: newerKey).inflection == 140)
        custom.macinTalkInflectionOverride[newerKey] = 100
        precondition(SpeechSettings.decode(custom.encoded())!.macinTalkSettings(.lion, voiceKey: newerKey).inflection == 100)
        precondition(SpeechSettings.decode(Data("{}".utf8))!.macinTalkSettings(.lion, voiceKey: newerKey).inflection == 140)
        let cacheJob = SpeechJob.from(ssml: "<speak>Safari</speak>", voiceKey: newerKey, settings: settings)
        precondition(MacinTalkProvider.cacheKey(cacheJob, voiceKey: newerKey, settings: settings)
            != MacinTalkProvider.cacheKey(cacheJob, voiceKey: newerKey, settings: custom))

        precondition(prepare("Read 10:38 PM") == "Red 10:38 PM")
        precondition(prepare("Read 3 chapters before Monday.") == "Read 3 chapters before Monday.")
        precondition(prepare("1 minute 9 seconds") == "1 minute 9 seconds")
        precondition(prepare("A minute detail, a minute ago") == "A minute detail, a minute ago")
        precondition(prepare("1 m 26 s") == "1 minute 26 seconds")
        precondition(prepare("23°C").contains("23 degrees"))
        precondition(prepare("x=2").contains("equals"))
        precondition(prepare("FACETIME SETTINGS JANESMITH4 HTTPS MCMXCIV")
            == "Facetime Settings Janesmith 4 HTTPS MCMXCIV")

        var entry = Pronunciation(match: "pineapple", replacement: "banana")
        settings.macinTalkPronunciations = [entry]
        precondition(prepare("pineapple") == "banana")
        entry.generations = [.lion]
        settings.macinTalkPronunciations = [entry]
        precondition(prepare("pineapple") == "banana")
        precondition(MacinTalkCompatibility.prepare("pineapple", voiceKey: "mt106/Alex", settings: settings) == "pineapple")
        entry.generations = [.snowleopard]
        entry.voiceIDs = ["com.pantheraspeech.lion.alex"]
        settings.macinTalkPronunciations = [entry]
        precondition(prepare("pineapple") == "banana")
        precondition(MacinTalkCompatibility.prepare("pineapple", voiceKey: "mt107/Victoria", settings: settings) == "pineapple")
        precondition(MacinTalkCompatibility.prepare("pineapple", voiceKey: "mt106/Alex", settings: settings) == "pineapple")
        entry.voiceIDs = []
        settings.macinTalkPronunciations = [entry]
        precondition(prepare("pineapple") == "pineapple")
        entry = Pronunciation(match: "Giulia", replacement: "J1UWlIYAX", phonemes: true)
        entry.voiceIDs = ["com.pantheraspeech.lion.alex"]
        settings.macinTalkPronunciations = [entry]
        precondition(prepare("Giulia").contains("[[inpt PHON]]J1UWlIYAX[[inpt TEXT]]"))
        settings.macinTalkPronunciations = []

        let dockXML = "<speak><prosody rate='219.99998%'>Dock<break time='500ms'/>  </prosody></speak>"
        let dock = SpeechJob.from(ssml: dockXML, voiceKey: key, settings: settings)
        precondition(dock.text == "Dock[[slnc 500]] ")
        precondition(dock.trailingPauseMs == 0 && dock.macinTalkPitchTenths == 0 && dock.pitch == 100)
        precondition(dock.macinTalkWPM == 396)
        let bare = SpeechJob.from(ssml: "<speak>Dock</speak>", voiceKey: key, settings: settings)
        precondition(bare.text == "Dock")
        precondition(MacinTalkProvider.cacheKey(dock, voiceKey: key, settings: settings)
            != MacinTalkProvider.cacheKey(bare, voiceKey: key, settings: settings))
        let silence = SpeechJob.from(ssml: "<speak><break time='500ms'/></speak>", voiceKey: key, settings: settings)
        precondition(silence.text.isEmpty && silence.trailingPauseMs == 500)
        let snowVoice = SpeechJob.from(ssml: dockXML, voiceKey: "mt106/Alex", settings: settings)
        precondition(snowVoice.text == "Dock[[slnc 500]] " && snowVoice.trailingPauseMs == 0)
        let snowSidebar = SpeechJob.from(ssml: "<speak>sidebar<break time='60ms'/>table<break time='250ms'/></speak>", voiceKey: "mt106/Alex", settings: settings)
        precondition(snowSidebar.text.hasSuffix("[[slnc 250]] ") && snowSidebar.trailingPauseMs == 0)
        var noSnowPauses = settings
        var snowProfile = settings.macinTalkSettings(.snowleopard)
        snowProfile.macPauses = false; noSnowPauses.macinTalk["snowleopard"] = snowProfile
        precondition(SpeechJob.from(ssml: dockXML, voiceKey: "mt106/Alex", settings: noSnowPauses).text == "Dock")
        let oldVoice = SpeechJob.from(ssml: dockXML, voiceKey: "mt105/Alex", settings: settings)
        precondition(oldVoice.text == "Dock[[slnc 500]] " && oldVoice.trailingPauseMs == 0)
        var lionProfile = settings.macinTalkSettings(.lion)
        lionProfile.macPauses = false; settings.macinTalk["lion"] = lionProfile
        precondition(SpeechJob.from(ssml: dockXML, voiceKey: key, settings: settings).text == "Dock")
        settings.macinTalk = [:]
        let literal = SpeechJob.from(ssml: "<speak>Dock[[slnc 500]]</speak>", voiceKey: key, settings: settings)
        precondition(literal.text == "Dock", "typed commands remain disabled")

        let cases = [
            ("receipt", "Read 10:38 PM"),
            ("duration", "1 minute 9 seconds. 1 m 26 s."),
            ("symbols", "23°C. x=2."),
            ("capitals", "FACETIME SETTINGS JANESMITH4 HTTPS MCMXCIV"),
            ("punctuation", "Use the lock button., Double Click ,  to Continue. Wait!, ok."),
            ("ordinary", "Read 3 chapters before Monday. A minute detail, a minute ago.")
        ]
        var corpus = [[String: Any]]()
        for (name, input) in cases {
            let xml = "<speak>" + input.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;") + "</speak>"
            let job = SpeechJob.from(ssml: xml, voiceKey: key, settings: settings)
            precondition(job.macinTalkWPM == 180)
            corpus.append(["name": name, "input": input, "prepared": job.text, "wpm": 180, "pmod": 100])
        }
        entry = Pronunciation(match: "pineapple", replacement: "banana")
        entry.voiceIDs = ["com.pantheraspeech.lion.alex"]
        settings.macinTalkPronunciations = [entry]
        corpus.append(["name": "custom-rule", "input": "pineapple", "prepared": prepare("pineapple"), "wpm": 180, "pmod": 100])
        if CommandLine.arguments.count > 1 {
            try JSONSerialization.data(withJSONObject: corpus, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("PASS Lion pronunciation defaults, receipt/duration/symbol/capitalization rules, generation/voice scopes and phoneme entries")
    }
}
