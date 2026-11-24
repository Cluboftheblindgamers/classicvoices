import Foundation
private final class BuildIdentityMarker {}

/// Distribution can supply separate identities for a side-by-side test copy.
/// Missing overrides retain Classic's identifiers for source compatibility.
enum BuildIdentity {
    static let isPantheraPort = true
    private static let configuration: [String: String] = {
        var bundles = [Bundle(for: BuildIdentityMarker.self), Bundle.main]
        for bundle in bundles where bundle.bundleURL.pathExtension == "appex" {
            var host = bundle.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            if host.lastPathComponent == "Contents" { host.deleteLastPathComponent() }
            if let bundle = Bundle(url: host) { bundles.append(bundle) }
        }
        var values: [String: String] = [:]
        for bundle in bundles {
            for key in ["ClassicVoicesTestCopy", "ClassicVoicesVoicePrefix", "ClassicVoicesSubtype",
                        "ClassicVoicesManufacturer", "ClassicVoicesAppGroup", "ClassicVoicesTestLabel"] where values[key] == nil {
                if let value = bundle.object(forInfoDictionaryKey: key) as? String, !value.isEmpty { values[key] = value }
            }
        }
        return values
    }()
    static func value(_ key: String) -> String? {
        configuration[key]
    }
    static var testLabel: String { value("ClassicVoicesTestLabel") ?? "Panthera port" }
    static var isTestCopy: Bool { value("ClassicVoicesTestCopy") == "YES" }
    static var voicePrefix: String { value("ClassicVoicesVoicePrefix") ?? "com.levigobin.ClassicVoices" }
    static func fourCC(_ key: String, fallback: UInt32) -> UInt32 {
        guard let value = value(key), value.utf8.count == 4 else { return fallback }
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
