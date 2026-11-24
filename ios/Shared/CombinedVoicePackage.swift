import Foundation

/// Converts an already-unzipped Apple combined voice project into the same
/// two-folder layout used by the existing premium/compact package downloader.
enum CombinedVoicePackage {
    enum PackageError: LocalizedError {
        case invalid
        var errorDescription: String? { "The download does not contain a complete compact and premium voice pair." }
    }
    static func prepare(assetData: URL, name: String, to destination: URL) throws -> [String] {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw PackageError.invalid }
        let fm=FileManager.default
        let children=try fm.contentsOfDirectory(at:assetData,includingPropertiesForKeys:nil)
        let projects=children.filter {
            fm.fileExists(atPath:$0.appendingPathComponent("compact/broker.hdr").path)
                && fm.fileExists(atPath:$0.appendingPathComponent("premium/broker.hdr").path)
        }
        guard projects.count==1 else { throw PackageError.invalid }
        // Validate both before moving either: incomplete pairs never reach the store.
        for kind in ["compact","premium"] {
            let broker=projects[0].appendingPathComponent("\(kind)/broker.hdr")
            let xml=try String(contentsOf:broker,encoding:.isoLatin1)
            guard let a=xml.range(of:"<voice>"), let b=xml.range(of:"</voice>",range:a.upperBound..<xml.endIndex),
                  String(xml[a.upperBound..<b.lowerBound]).caseInsensitiveCompare(name) == .orderedSame else { throw PackageError.invalid }
        }
        var folders=[String]()
        for kind in ["compact","premium"] {
            let folder=name+(kind=="compact" ? "Compact" : "")
            try fm.moveItem(at:projects[0].appendingPathComponent(kind),to:destination.appendingPathComponent(folder))
            folders.append(folder)
        }
        return folders
    }
}
