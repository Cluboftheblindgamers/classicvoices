// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation

/// One Mac OS X speech generation. Classic maps these profiles to mt104..mt107
/// and serializes MacinTalk requests through its shared engine producer.
public enum Generation: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiger
    case leopard
    case snowleopard
    case lion
#if CV_IOS10_ALEX
    case ios10Alex
#endif

    public var id: String { rawValue }

    /// How a person reads it: "Snow Leopard".
    public var label: String {
        switch self {
        case .tiger: return "Tiger"
        case .leopard: return "Leopard"
        case .snowleopard: return "Snow Leopard"
        case .lion: return "Lion"
#if CV_IOS10_ALEX
        case .ios10Alex: return "iOS 10 Alex"
#endif
        }
    }

    /// "Mac OS X 10.5", for the import screen.
    public var release: String {
        switch self {
        case .tiger: return "Mac OS X 10.4"
        case .leopard: return "Mac OS X 10.5"
        case .snowleopard: return "Mac OS X 10.6"
        case .lion: return "Mac OS X 10.7"
#if CV_IOS10_ALEX
        case .ios10Alex: return "iOS 10.3.4"
#endif
        }
    }

    /// The generation name the host's volume tables are keyed by.
    public var hostName: String { rawValue }

    /// NVDA's measured defaults: Tiger 100, the normalised generations 90.
    public var defaultVolume: Int { self == .tiger ? 100 : 90 }

    /// Older Mac VoiceOver used 100; the iOS 10 Alex engine reports 140.
    public var defaultInflection: Int {
#if CV_IOS10_ALEX
        if self == .ios10Alex { return 140 }
#endif
        return 100
    }

    /// Tiger's engine has no phrasing threshold to set.
    /// Leopard's engine asks for the same threshold but does something else
    /// with it: any value at all makes Alex read word by word, every word
    /// stressed, and 45% slower (measured; the setting's scale belongs to
    /// Snow Leopard and Lion).  So Leopard keeps its own phrasing.
    public var supportsPhrasing: Bool { self == .snowleopard || self == .lion || preservesUnicode }

    /// Lion's input modes are excluded from embedded commands, as on NVDA.
    public var excludesInputModeCommands: Bool { self == .lion || preservesUnicode }
    public var preservesUnicode: Bool {
#if CV_IOS10_ALEX
        return self == .ios10Alex
#else
        return false
#endif
    }

    /// The generation a speech extension serves, from its Info.plist.
    public static var current: Generation? {
        (Bundle.main.object(forInfoDictionaryKey: "PantheraGeneration") as? String)
            .flatMap(Generation.init(rawValue:))
    }
}
