import Foundation
@testable import ClassicPortTest

@main struct AnnouncementPauseCheck {
    static func main() throws {
        var settings = SpeechSettings()
        let key = "mt106/Alex"
        let xml = "<speak>sidebar<break time='60ms'/>table<break time='250ms'/>Row 4 of 11<break time='250ms'/></speak>"
        func job(_ text: String? = nil) -> SpeechJob { SpeechJob.from(ssml: text ?? xml, voiceKey: key, settings: settings) }
        let original = job()
        precondition(settings.macinTalkSettings(.snowleopard).announcementPausePercent == 100)
        var profile = settings.macinTalkSettings(.snowleopard)
        profile.announcementPausePercent = 50; settings.macinTalk["snowleopard"] = profile
        let half = job()
        precondition(half.text.contains("[[slnc 30]]") && half.text.contains("[[slnc 125]]"))
        precondition(half.macinTalkWPM == original.macinTalkWPM && half.pitch == original.pitch)
        precondition(half.text.replacingOccurrences(of:"[[slnc 30]]",with:"[[slnc 60]]").replacingOccurrences(of:"[[slnc 125]]",with:"[[slnc 250]]") == original.text)
        precondition(MacinTalkProvider.cacheKey(half,voiceKey:key,settings:settings) != MacinTalkProvider.cacheKey(original,voiceKey:key,settings:SpeechSettings()))
        precondition(job("<speak><break time='500ms'/></speak>").trailingPauseMs == 250)
        let rich = job("<speak>One<mark name='a'/><break time='400ms'/>two<break time='600ms'/></speak>")
        precondition(rich.text.contains("pause=200") && rich.trailingPauseMs == 300)
        let vocalizer = SpeechJob.from(ssml:"<speak>One<break time='400ms'/>two<break time='600ms'/></speak>",voiceKey:"ios7/en-US",settings:settings)
        precondition(vocalizer.text.contains("pause=400") && vocalizer.trailingPauseMs == 600)
        profile.acceptCommands = true; settings.macinTalk["snowleopard"] = profile
        precondition(job("<speak>One [[slnc 444]] two</speak>").text.contains("[[slnc 444]]"),"literal commands must not be scaled")
        profile.announcementPausePercent = 0; settings.macinTalk["snowleopard"] = profile
        precondition(!job().text.contains("[[slnc") && job().trailingPauseMs == 0)
        precondition(job("<speak><break time='500ms'/></speak>").trailingPauseMs == 0)
        profile.announcementPausePercent = 100; profile.acceptCommands = false; settings.macinTalk["snowleopard"] = profile
        precondition(job().text == original.text)
        for (generation, legacyKey) in [(Generation.tiger, "mt104/Fred"), (.leopard, "mt105/Alex")] {
            let finalXML = "<speak>Dock<break time='500ms'/></speak>"
            var legacy = SpeechSettings()
            func legacyJob() -> SpeechJob { SpeechJob.from(ssml: finalXML, voiceKey: legacyKey, settings: legacy) }
            precondition(legacyJob().text == "Dock[[slnc 500]] " && legacyJob().trailingPauseMs == 0)
            var profile = legacy.macinTalkSettings(generation)
            profile.announcementPausePercent = 50; legacy.macinTalk[generation.rawValue] = profile
            precondition(legacyJob().text == "Dock[[slnc 250]] " && legacyJob().trailingPauseMs == 0)
            profile.announcementPausePercent = 0; legacy.macinTalk[generation.rawValue] = profile
            precondition(legacyJob().text == "Dock" && legacyJob().trailingPauseMs == 0)
            profile.announcementPausePercent = 100; profile.macPauses = false
            legacy.macinTalk[generation.rawValue] = profile
            precondition(legacyJob().text == "Dock" && legacyJob().trailingPauseMs == 0)
        }
        let old = try JSONDecoder().decode(PantheraSettings.self,from:Data("{}".utf8))
        precondition(old.announcementPausePercent == 100)
        let low = try JSONDecoder().decode(PantheraSettings.self,from:Data("{\"announcementPausePercent\":-5}".utf8))
        let high = try JSONDecoder().decode(PantheraSettings.self,from:Data("{\"announcementPausePercent\":500}".utf8))
        precondition(low.announcementPausePercent == 0 && high.announcementPausePercent == 100)
        settings.macinTalk["snowleopard"]?.announcementPausePercent = 40
        let exported = try PantheraSettingsTransfer.exported(settings)
        let imported = try PantheraSettingsTransfer.imported(exported,preserving:SpeechSettings())
        precondition(imported.macinTalkSettings(.snowleopard).announcementPausePercent == 40)
        let suite="pause-test.\(UUID().uuidString)";let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        settings.macinTalkSettings(.snowleopard).save(.snowleopard,to:defaults)
        precondition(PantheraSettings.load(.snowleopard,from:defaults).announcementPausePercent == 40)
        print("PASS announcement pause scaling, zero/default behavior, literal command protection, rich SSML, Vocalizer isolation, cache keys and settings persistence")
    }
}
