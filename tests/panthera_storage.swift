import Foundation
@testable import ClassicPortTest

@main struct StorageChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("classic-port-storage-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        setenv("CV_PORT_ROOT", root.path, 1)
        let engine = root.appendingPathComponent("mt105/MacinTalk")
        try fm.createDirectory(at: engine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: engine)
        precondition(VoiceCatalog.containsEngineData(in: root), "Leopard-only data must be usable without iOS 6")
        precondition(VoiceCatalog.builtIn.isEmpty)
        let voice = root.appendingPathComponent("mt105/Voices/Fred.SpeechVoice/Contents/Resources/VoiceDescription")
        try fm.createDirectory(at: voice.deletingLastPathComponent(), withIntermediateDirectories: true)
        var description = Data(repeating: 0, count: 100)
        description[16] = 4; description.replaceSubrange(17..<21, with: Data("Fred".utf8))
        try description.write(to: voice)
        precondition(VoiceCatalog.builtIn.map(\.key) == ["mt105/Fred"], "nested voice install must invalidate catalog")
        try fm.removeItem(at: root.appendingPathComponent("mt105/Voices/Fred.SpeechVoice"))
        precondition(VoiceCatalog.builtIn.isEmpty, "removed voice must disappear without restarting process")

        let ops = StoreOps(root: root)
        var settings = SpeechSettings()
        settings.macinTalk["snowleopard"] = PantheraSettings()
        let file = root.appendingPathComponent(SpeechSettings.file)
        let first = settings.encoded()
        precondition(ops.perform(["op": "write", "path": SpeechSettings.file, "data": first])["ok"] as? Bool == true)
        precondition(SpeechSettings.current.macinTalkSettings(.snowleopard).inflection == 100)
        let oldDate = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        settings.macinTalk["snowleopard"]!.inflection = 140
        precondition(ops.perform(["op": "write", "path": SpeechSettings.file, "data": settings.encoded()])["ok"] as? Bool == true)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        precondition(SpeechSettings.current.macinTalkSettings(.snowleopard).inflection == 140,
                     "same-date/same-size atomic replacement must reload settings")
        try Data("broken JSON".utf8).write(to: file, options: .atomic)
        precondition(SpeechSettings.current.macinTalkSettings(.snowleopard).inflection == 140, "damaged settings must retain last valid values")
        try fm.removeItem(at: file)
        precondition(SpeechSettings.current.macinTalkSettings(.snowleopard).inflection == 100, "intentional settings deletion restores defaults")
        let target = root.appendingPathComponent("legacy-settings.json")
        try first.write(to: target)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        _ = ops.perform(["op": "write", "path": SpeechSettings.file, "data": settings.encoded()])
        let destination = try fm.destinationOfSymbolicLink(atPath: file.path)
        let linkedData = try Data(contentsOf: target)
        precondition(destination == target.path)
        precondition(SpeechSettings.decode(linkedData) == settings, "legacy group link must see atomic update")
        precondition(SpeechSettings.current.macinTalkSettings(.snowleopard).inflection == 140)
        settings.macinTalk["snowleopard"]!.inflection = 80
        _ = ops.perform(["op": "write", "path": SpeechSettings.file, "data": settings.encoded()])
        precondition(SpeechSettings.current.macinTalkSettings(.snowleopard).inflection == 80, "target replacement behind unchanged group symlink must reload")

        // Installing over an installed voice: discard, put, commit (VoiceStore.install).
        func put(_ rel: String, _ text: String) -> Bool {
            ops.perform(["op": "put", "path": rel, "data": Data(text.utf8), "offset": NSNumber(value: 0)])["ok"] as? Bool == true
        }
        func installed(_ rel: String) -> String? {
            (try? Data(contentsOf: root.appendingPathComponent(rel))).map { String(decoding: $0, as: UTF8.self) }
        }
        func leftovers() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasPrefix(".staging-replaced-") }
        }
        let voiceDir = "ios6/en-GB"
        _ = ops.perform(["op": "discard"])
        precondition(put(voiceDir + "/broker.hdr.asset", "old voice"))
        precondition(ops.perform(["op": "commit", "path": voiceDir])["ok"] as? Bool == true)
        precondition(installed(voiceDir + "/broker.hdr.asset") == "old voice")
        // Nothing staged (another install's discard came in between, or an
        // empty folder was sent): the installed voice must survive.
        _ = ops.perform(["op": "discard"])
        let empty = ops.perform(["op": "commit", "path": voiceDir])
        precondition(empty["error"] != nil, "a commit with nothing staged must report an error")
        precondition(installed(voiceDir + "/broker.hdr.asset") == "old voice", "a commit with nothing staged must keep the installed voice")
        // An ordinary replacement swaps the whole folder and leaves nothing aside.
        precondition(put(voiceDir + "/broker.hdr.asset", "new voice"))
        precondition(ops.perform(["op": "commit", "path": voiceDir])["ok"] as? Bool == true)
        precondition(installed(voiceDir + "/broker.hdr.asset") == "new voice", "commit must install the new copy")
        precondition(leftovers().isEmpty, "a successful replacement leaves no set-aside copy")
        // A store link into the App Group (adoptLegacy): replacing it still
        // removes the group's copy, as before, once the new one is in place.
        let group = root.appendingPathComponent("group-voices/ios5-en-GB")
        try fm.createDirectory(at: group, withIntermediateDirectories: true)
        try Data("group voice".utf8).write(to: group.appendingPathComponent("broker.hdr.asset"))
        try fm.createDirectory(at: root.appendingPathComponent("ios5"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("ios5/en-GB"), withDestinationURL: group)
        _ = ops.perform(["op": "discard"])
        precondition(put("ios5/en-GB/broker.hdr.asset", "store voice"))
        precondition(ops.perform(["op": "commit", "path": "ios5/en-GB"])["ok"] as? Bool == true)
        precondition(installed("ios5/en-GB/broker.hdr.asset") == "store voice")
        precondition((try? fm.destinationOfSymbolicLink(atPath: root.appendingPathComponent("ios5/en-GB").path)) == nil,
                     "the link is replaced by the store's own copy")
        precondition(!fm.fileExists(atPath: group.path), "the replaced link's App Group copy is removed after the new copy is in place")
        precondition(leftovers().isEmpty)
        print("PASS MT-only discovery, nested install/removal refresh, atomic settings, same-date replacement, corrupt-file recovery, legacy group links and installs that keep the installed voice when nothing arrives")
    }
}
