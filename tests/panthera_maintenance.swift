// Panthera regression corpus; see third_party/panthera/LICENSE.
import Foundation
@testable import ClassicPortTest

// This standalone check compiles the real Shared sources without touching
// a user's App Group or preferences. See tools/apple_maintenance_check.sh.

@main struct MaintenanceCheck {
    static func require(_ ok: Bool, _ message: String) {
        precondition(ok, message)
    }

    static func main() throws {
        var settings = PantheraSettings()
        require(settings.wpm(requestMultiplier: 1) == 180, "ordinary rate")
        require(settings.wpm(requestMultiplier: 1e100) == 500, "huge rate")
        require(settings.wpm(requestMultiplier: .nan) == 180, "NaN rate")
        require(settings.wpm(requestMultiplier: .infinity) == 180, "infinite rate")
        settings.rateBoost = true
        require(settings.wpm(requestMultiplier: 1e308) == 1200, "boost overflow")
        require(settings.wpm(requestMultiplier: 2) == 720, "ordinary boosted rate")
        require(SSMLRequest.pitch("1e100st") == 120, "huge positive pitch")
        require(SSMLRequest.pitch("-1e100st") == -120, "huge negative pitch")
        require(SSMLRequest.pitch("NaNst") == nil, "NaN pitch")
        require(SSMLRequest.pitch("infst") == nil, "infinite pitch")
        require(SSMLRequest.pitch("+2st") == 20, "ordinary pitch")
        require(SSMLRequest.breakMs(time: "1e300s", strength: nil) == 1000, "huge break")
        require(SSMLRequest.breakMs(time: "NaNms", strength: nil) == 0, "NaN break")
        require(SSMLRequest.breakMs(time: "infms", strength: nil) == 0, "infinite break")
        require(SSMLRequest.breakMs(time: "-1s", strength: nil) == 0, "negative break")
        require(SSMLRequest.breakMs(time: "250ms", strength: nil) == 250, "ordinary break")
        let request = SSMLRequest(ssml: "<speak><prosody rate=\"1e100\" pitch=\"1e100st\">Hello<break time=\"1e300s\"/>world.</prosody></speak>")
        require(request.pitchTenths == 120 && settings.wpm(requestMultiplier: request.rateMultiplier) == 1200, "SSML integration")
        // A capital letter at a raised pitch is its own piece, at that pitch.
        let capital = SSMLRequest(ssml: "<speak><prosody rate=\"150%\" pitch=\"+1st\">Delete <prosody pitch=\"+20%\">C</prosody> app</prosody></speak>")
        let parts = capital.pieces(natural: true, wpm: 180)
        require(capital.pitchTenths == 10 && parts.count == 3, "pitch pieces")
        require(parts[0].pitchTenths == nil && parts[1].pitchTenths == 10 + 32 && parts[1].text == "C"
                && parts[2].pitchTenths == nil, "pitch piece values")
        require(SSMLRequest(ssml: "<speak><prosody pitch=\"+2st\">Plain text</prosody></speak>").segments.count == 1, "no pitch change, one piece")
        // VoiceOver's short pause: a comma alone, or (as on Mac OS X) a
        // silence of that length before the comma, kept through filtering.
        let role = SSMLRequest(ssml: "<speak>Configure <break time=\"60ms\"/> button</speak>")
        require(role.pieces(natural: true, wpm: 180).map(\.text) == ["Configure, button"], "pause as a comma")
        let silent = role.pieces(natural: true, wpm: 180, macVoiceOver: true, macPauses: true)
        let split = silent.count == 1 ? SSMLRequest.splitAtMarks(silent[0].text) : []
        require(split.count == 2 && split[0].text == "\"Configure\" " && split[0].command == "[[slnc 60]]"
                && split[1].text == " , button" && split[1].command == nil, "pause as VoiceOver on Mac OS X")
        require(SSMLRequest.splitAtMarks("a").count == 1, "no marks")
        let iosPause = SSMLRequest(ssml: "<speak><prosody>Sam,<break time=\"276ms\"/> Online</prosody></speak>")
        require(iosPause.pieces(natural: true, wpm: 180, macPauses: true).first.map { SSMLRequest.splitAtMarks($0.text).first?.command } == "[[slnc 60]]",
                "pause capped at 60 ms")
        require(role.pieces(natural: true, wpm: 180, macVoiceOver: true).map(\.text) == ["Configure, button"], "pauses off: a comma")
        // Text in another script: the name of its language.
        require(SpeechText.nameForeignText("Offline, Badge, \u{0645}\u{0637}\u{0631}") == "Offline, Badge,  Arabic ", "Arabic badge")
        require(SpeechText.nameForeignText("\u{05E9}\u{05DC}\u{05D5}\u{05DD} \u{05E2}\u{05D5}\u{05DC}\u{05DD}, ok") == " Hebrew , ok", "a phrase is one name")
        require(SpeechText.nameForeignText("caf\u{00E9} na\u{00EF}ve") == "caf\u{00E9} na\u{00EF}ve", "Latin left alone")
        let russian = SpeechText.nameForeignText("\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}, \u{043A}\u{0430}\u{043A} \u{0434}\u{0435}\u{043B}\u{0430}")
        require(!russian.contains("\u{041F}") && russian.contains(","), "Cyrillic: " + russian)
        require(SpeechText.tidyPunctuation("Use the lock button., Double Click ,  to Continue. Wait!, ok, 3.5, a.b")
                == "Use the lock button. Double Click ,  to Continue. Wait! ok, 3.5, a.b", "sentence end before a comma")
        require(SpeechText.beforeNumbers("Read 10:45 AM, read 3, I read it, a minute ago, minute 3", generation: .snowleopard)
                == "Read 10:45 AM, read 3, I read it, a minute ago, minnitt 3", "read before a number")
        for generation in [Generation.tiger, .leopard, .snowleopard] {
            require(SpeechText.beforeNumbers("1 minute 9 seconds", generation: generation)
                    == "1 minnitt 9 seconds", "duration minute before seconds")
            require(SpeechText.beforeNumbers("A minute detail, a minute ago", generation: generation)
                    == "A minute detail, a minute ago", "minute outside numeric context")
        }
        require(SpeechText.beforeNumbers("1 minute 9 seconds", generation: .lion)
                == "1 minute 9 seconds", "Lion duration stays natural")
        require(SpeechText.beforeNumbers("minute 3, Minute 12, a minute ago", generation: .tiger)
                == "minnitt 3, Minnitt 12, a minute ago", "minute before a number on Tiger")
        require(SpeechText.separateDigits("stormfox210, nightowl99, mp3, 4K, x1") == "stormfox 210, nightowl 99, mp3, 4K, x1", "digits stuck to a word")
        require(SpeechText.beforeNumbers("Read 10:45 AM", generation: .snowleopard) == "Red 10:45 AM", "receipt timestamp")
        require(SpeechText.beforeNumbers("Read 3 chapters before Monday.", generation: .snowleopard) == "Read 3 chapters before Monday.", "imperative read")
        for gen in Generation.allCases {
            for body in [
                "\u{200e}Read 10:38\u{202f}PM <break time='60ms'/> text",
                "Example message<break time='300ms'/>\u{200e}Read 10:38\u{202f}PM <break time='60ms'/> text",
                "Read 10:38 PM, text"
            ] {
                let request = SSMLRequest(ssml: "<speak><prosody rate='189.99998%'>" + body + "</prosody></speak>")
                let output = request.pieces(natural: true, wpm: 342, macVoiceOver: true, macPauses: true, style: .of(gen)).map {
                    Pronunciations.prepare($0.text, entries: [], settings: settings, generation: gen, internalMarks: true)
                }.joined()
                require(output.contains("Red 10:38") && !output.contains("Read 10:38"), "captured Messages receipt context")
            }
            for input in ["Read aloud", "Read files, ran commands", "Read 3 chapters", "Please read 10:38 PM", "Read 10:38 PM aloud"] {
                require(SpeechText.beforeNumbers(input, generation: gen) == input, "reading instruction keeps present tense")
            }
        }
        var clockSettings = settings
        clockSettings.twentyFourHour = true
        require(SpeechText.prepare("Read 10:38 PM", settings: clockSettings, generation: .leopard).hasPrefix("Red "),
                "receipt correction precedes clock expansion")
        for gen in Generation.allCases {
            let minute = gen == .lion ? "minute" : "minnitt"
            for input in ["1 m 26 s", "1m26s", "1 m\u{202f}26 s"] {
                require(SpeechText.prepare(input, settings: settings, generation: gen)
                        == "1 " + minute + " 26 seconds", "paired duration units")
            }
            require(SpeechText.prepare("2 h 1 m 1 s", settings: settings, generation: gen)
                    == "2 hours 1 " + minute + " 1 second", "duration singular units")
            require(SpeechText.prepare("1m26s", settings: settings, generation: gen, spelling: true)
                    == "1m26s", "spelling is not expanded as a duration")
        }
        for input in ["1 m", "26 s", "x1m26s", "1 M 26 S", "1.5m26s", "user_1m26s", "1m26speed"] {
            require(SpeechText.expandDurations(input) == input, "ambiguous unit or identifier stays intact")
        }
        let mixedScripts = SpeechText.prepare("مطر 42 🚀 עולם", settings: settings, generation: .snowleopard)
        require(mixedScripts.contains("42") && mixedScripts.contains("rocket") && mixedScripts.contains("Arabic") && mixedScripts.contains("Hebrew"), "mixed scripts preserve content: " + mixedScripts)
        let rawMark = "before\u{FFFFD}after"
        require(!Pronunciations.prepare(rawMark, entries: [], settings: settings, generation: .snowleopard).contains("[["), "plain text cannot supply marks")
        let markedRequest = SSMLRequest(ssml: "<speak>" + rawMark + "</speak>")
        let markedText = markedRequest.pieces(natural: true, wpm: 180, macVoiceOver: true, macPauses: true).map {
            Pronunciations.prepare($0.text, entries: [], settings: settings, generation: .snowleopard, internalMarks: true)
        }.joined()
        require(!markedText.contains("[["), "XML cannot supply marks")
        let markedReplacement = Pronunciation(match: "word", replacement: rawMark)
        require(!Pronunciations.prepare("word", entries: [markedReplacement], settings: settings, generation: .snowleopard, internalMarks: true).contains("[["), "replacement cannot supply marks")
        for gen in Generation.allCases {
            for ms in [250, 300, 500] {
                let request = SSMLRequest(ssml: "<speak>TextEdit<break time='\(ms)ms'/>window</speak>")
                let output = request.pieces(natural: true, wpm: 180, macVoiceOver: true, macPauses: true, style: .of(gen)).map {
                    Pronunciations.prepare($0.text, entries: [], settings: settings, generation: gen, internalMarks: true)
                }.joined()
                require(output.contains("[[slnc \(ms)]]"), "explicit long pause on " + gen.rawValue)
                let separator = gen == .lion ? " " : gen == .snowleopard ? " , " : " ,  "
                require(output == "\"TextEdit\" [[slnc \(ms)]]" + separator + "window",
                        "long pause retains role punctuation on " + gen.rawValue)
                for label in ["Done.", "Done?", "Done!", "Done,"] {
                    let punctuated = SSMLRequest(ssml: "<speak>\(label)<break time='\(ms)ms'/>window</speak>")
                    let text = punctuated.pieces(natural: true, wpm: 180, macVoiceOver: true, macPauses: true, style: .of(gen)).map {
                        Pronunciations.prepare($0.text, entries: [], settings: settings, generation: gen, internalMarks: true)
                    }.joined()
                    require(text == label + " [[slnc \(ms)]] window", "existing punctuation stays intact")
                }
            }
        }
        for gen in Generation.allCases {
            let degree = SpeechText.prepare("23°", settings: settings, generation: gen)
            require(degree.contains("23 degrees"), "degree symbol on " + gen.rawValue)
            let code = SpeechText.prepare("x=23", settings: settings, generation: gen)
            require(code.contains("equals"), "equals symbol on " + gen.rawValue)
            require(SpeechText.prepare("23℃ 23℉", settings: settings, generation: gen).contains("degrees Celsius"), "temperature glyphs")
            let spelled = SSMLRequest(ssml: "<speak><prosody><say-as interpret-as='characters'>a=b°</say-as></prosody></speak>")
            let result = spelled.pieces(natural: true, wpm: 180, macVoiceOver: true, macPauses: true, style: .of(gen)).map {
                Pronunciations.prepare($0.text, entries: [], settings: settings, generation: gen, internalMarks: true)
            }.joined()
            require(result.contains("[[char LTRL]]a[[char NORM]] equals [[char LTRL]]b[[char NORM]] degrees [[char LTRL]][[char NORM]]"), "symbol names inside character mode")
        }
        // A letter read by itself goes in letter mode; capitals and deletions
        // at VoiceOver on Mac OS X's pitches.
        let letter = SSMLRequest(ssml: "<speak><prosody rate=\"190%\"><prosody pitch=\"+50.0%\"><say-as interpret-as=\"characters\"> a</say-as> </prosody></prosody></speak>")
        let letterParts = letter.pieces(natural: true, wpm: 180, macVoiceOver: true).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        require(letterParts.count == 1 && letterParts[0].pitchTenths == nil
                && SSMLRequest.splitAtMarks(letterParts[0].text).map { $0.command ?? "" }.joined()
                    == "[[pbas +9.0]][[char LTRL]][[char NORM]][[pbas -9.0]][[slnc 60]]",
                "capital letter as on Mac OS X")
        require(letter.pieces(natural: true, wpm: 180).first { $0.pitchTenths != nil }?.pitchTenths == 70, "capital letter pitch otherwise")
        // Leopard's VoiceOver: capitals +6, no closing silence, pauses a comma.
        let leo = SSMLRequest.VoiceOverStyle.of(.leopard)
        let leoCapital = letter.pieces(natural: true, wpm: 180, macVoiceOver: true, style: leo)
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        require(leoCapital.count == 1 && SSMLRequest.splitAtMarks(leoCapital[0].text).map { $0.command ?? "" }.joined()
                    == "[[pbas +6.0]][[char LTRL]][[char NORM]][[pbas -6.0]]", "capital as on Leopard")
        require(role.pieces(natural: true, wpm: 180, macVoiceOver: true, macPauses: true, style: leo).map(\.text) == ["\"Configure\" ,  button"],
                "Leopard's pause: a quoted name and a spaced comma")
        let lion = SSMLRequest.VoiceOverStyle.of(.lion)
        require(role.pieces(natural: true, wpm: 180, macVoiceOver: true, macPauses: true, style: lion).map(\.text) == ["\"Configure\" button"],
                "Lion's pause: none")
        let lionDeleted = SSMLRequest(ssml: "<speak><prosody rate=\"160%\"><prosody pitch=\"-40.0%\"><say-as interpret-as=\"characters\">s</say-as></prosody></prosody></speak>")
            .pieces(natural: true, wpm: 180, macVoiceOver: true, style: lion).filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        require(lionDeleted.count == 1 && SSMLRequest.splitAtMarks(lionDeleted[0].text).map { $0.command ?? "" }.joined()
                    == "[[pbas -6.0]][[pbas +0.0]][[char LTRL]][[char NORM]][[pbas -0.0]][[pbas +6.0]]", "deletion as on Lion")
        require(SSMLRequest.macVoiceOverPitch(SSMLRequest.pitch("-30%")!) == -75
                && SSMLRequest.macVoiceOverPitch(SSMLRequest.pitch("-40%")!) == SSMLRequest.pitch("-40%")!
                && SSMLRequest.macVoiceOverPitch(SSMLRequest.pitch("-40%")!, spelled: true) == -75, "deletion pitch")
        require(SSMLRequest.splitAtMarks(SSMLRequest.lettersOn + "x").last?.command == "[[char NORM]]", "letter mode closed")
        // Spelled characters in Snow Leopard VoiceOver's forms (traced).
        func engineText(_ ssml: String) -> String {
            SSMLRequest(ssml: ssml).pieces(natural: true, wpm: 180, macVoiceOver: true)
                .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { SSMLRequest.splitAtMarks($0.text).map { $0.text + ($0.command ?? "") }.joined() }
                .joined(separator: "|")
        }
        require(engineText("<speak><say-as interpret-as=\"characters\">o</say-as></speak>")
                == "[[pbas +0.0]][[char LTRL]]o[[char NORM]][[pbas -0.0]][[slnc 60]] ", "plain letter as on Mac OS X")
        require(engineText("<speak><say-as interpret-as=\"characters\">1</say-as></speak>")
                == "[[char LTRL]]1[[char NORM]][[slnc 60]] ", "digit as on Mac OS X")
        require(engineText("<speak><prosody rate=\"160%\"><prosody pitch=\"-40.0%\"><say-as interpret-as=\"characters\"> s</say-as> </prosody></prosody></speak>")
                == "[[pbas -7.5]][[pbas +0.0]][[char LTRL]] s[[char NORM]][[pbas -0.0]][[slnc 60]] [[pbas +7.5]]", "deleted letter as on Mac OS X: " + engineText("<speak><prosody rate=\"160%\"><prosody pitch=\"-40.0%\"><say-as interpret-as=\"characters\"> s</say-as> </prosody></prosody></speak>"))
        require(SpeechText.capitalsAsWords("Open SETTINGS and CLAUDE, not USB or XVII; JANESMITH4") == "Open Settings and Claude, not USB or XVII; Janesmith4",
                "capitals as words")
        let pauses = SSMLRequest(ssml: "<speak>" + String(repeating: "<break time=\"1e300s\"/>", count: 100) + "</speak>")
        require(pauses.pauseOnlyMs == 1000, "bounded pause sum")
        let merged = SSMLRequest.merged([.init(text: "a", pauseAfterMs: Int.max), .init(text: "", pauseAfterMs: Int.max), .init(text: "b")])
        require(merged[0].pauseAfterMs == 1000, "bounded segment sum")
        print("PASS SSML bounds and normal values")

    }
}
