import Foundation
@testable import ClassicPortTest

@main struct IOS10VocalizerChecks {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("ios10-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        setenv("CV_PORT_ROOT",root.path,1)
        let engine=root.appendingPathComponent("ios10/voiced")
        try FileManager.default.createDirectory(at:engine.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data([0]).write(to:engine)
        precondition(VoiceCatalog.entries.isEmpty,"Engine-only iOS10 must not advertise uninstalled voices")
        let broker=root.appendingPathComponent("ios10/en-US/broker.hdr.asset")
        try FileManager.default.createDirectory(at:broker.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("<NUANCE><voice>Samantha</voice></NUANCE>".utf8).write(to:broker)
        VoiceCatalog.invalidateEnhanced()
        let voice=VoiceCatalog.entries.first!
        precondition(voice.key=="ios10e/en-US" && voice.name=="Samantha" && voice.enhanced && !voice.fixedPitch)
        precondition(voice.displayName.contains("iOS 10 Enhanced") && !voice.displayName.contains("Alex"))
        precondition(VoiceCatalog.providerVoices.count==1)
        try FileManager.default.removeItem(at:broker.deletingLastPathComponent())
        VoiceCatalog.invalidateEnhanced()
        precondition(VoiceCatalog.entries.isEmpty,"Removing iOS10 data must withdraw its voice")
        let project=root.appendingPathComponent("unpacked/AssetData/tom")
        for kind in ["compact","premium"] {
            let folder=project.appendingPathComponent(kind)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let model=kind=="compact" ? "bet3" : "full_vssq5f22"
            try Data("<NUANCE><voice>Tom</voice><langcode>ENU</langcode><voicemodel>\(model)</voicemodel></NUANCE>".utf8).write(to:folder.appendingPathComponent("broker.hdr"))
        }
        let folders=try CombinedVoicePackage.prepare(assetData:project.deletingLastPathComponent(),name:"Tom",to:engine.deletingLastPathComponent())
        precondition(folders==["TomCompact","Tom"])
        VoiceCatalog.invalidateEnhanced()
        let pair=VoiceCatalog.entries
        precondition(Set(pair.map(\.key))==["ios10/Tom","ios10/TomCompact"])
        precondition(pair.first{$0.key=="ios10/Tom"}!.premium)
        precondition(!pair.first{$0.key=="ios10/TomCompact"}!.premium)
        precondition(pair.allSatisfy{!$0.fixedPitch})
        try FileManager.default.removeItem(at:root.appendingPathComponent("ios10/Tom"))
        VoiceCatalog.invalidateEnhanced()
        precondition(VoiceCatalog.entries.map(\.key)==["ios10/TomCompact"],"Removing Premium must keep Compact")
        let incomplete=root.appendingPathComponent("invalid/AssetData/tom/compact")
        try FileManager.default.createDirectory(at:incomplete,withIntermediateDirectories:true)
        try Data("<voice>Tom</voice>".utf8).write(to:incomplete.appendingPathComponent("broker.hdr"))
        do {
            _=try CombinedVoicePackage.prepare(assetData:incomplete.deletingLastPathComponent().deletingLastPathComponent(),name:"Tom",to:root)
            preconditionFailure("An incomplete voice pair must be rejected")
        } catch CombinedVoicePackage.PackageError.invalid { }
        print("PASS iOS10 engine-only exclusion, installed discovery, stable IDs, labels, pitch capability, combined pair import, incomplete-pair rejection and independent removal")
    }
}
