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
        print("PASS MT-only discovery, nested install/removal refresh, atomic settings, same-date replacement, corrupt-file recovery and legacy group links")
    }
}
