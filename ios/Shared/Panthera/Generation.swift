// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation

/// One Mac OS X speech engine generation. Each one is its own speech
/// extension -- its own process -- because the host maps one generation per
/// process and has no unload path (src/tiger_host_jni.h). That is the same
/// shape NVDA ("one synthesizer per generation") and Android ("one private
/// worker per generation") already settled on.
public enum Generation: String, CaseIterable, Codable, Identifiable, Sendable {
    case tiger
    case leopard
    case snowleopard
    case lion

    public var id: String { rawValue }

    /// How a person reads it: "Snow Leopard".
    public var label: String {
        switch self {
        case .tiger: return "Tiger"
        case .leopard: return "Leopard"
        case .snowleopard: return "Snow Leopard"
        case .lion: return "Lion"
        }
    }

    /// "Mac OS X 10.5", for the import screen.
    public var release: String {
        switch self {
        case .tiger: return "Mac OS X 10.4"
        case .leopard: return "Mac OS X 10.5"
        case .snowleopard: return "Mac OS X 10.6"
        case .lion: return "Mac OS X 10.7"
        }
    }

    /// The generation name the host's volume tables are keyed by.
    public var hostName: String { rawValue }

    /// NVDA's measured defaults: Tiger 100, the normalised generations 90.
    public var defaultVolume: Int { self == .tiger ? 100 : 90 }

    /// Tiger's engine has no phrasing threshold to set.
    /// Leopard's engine asks for the same threshold but does something else
    /// with it: any value at all makes Alex read word by word, every word
    /// stressed, and 45% slower (measured; the setting's scale belongs to
    /// Snow Leopard and Lion).  So Leopard keeps its own phrasing.
    public var supportsPhrasing: Bool { self == .snowleopard || self == .lion }

    /// Lion's input modes are excluded from embedded commands, as on NVDA.
    public var excludesInputModeCommands: Bool { self == .lion }

    /// The generation a speech extension serves, from its Info.plist.
    public static var current: Generation? {
        (Bundle.main.object(forInfoDictionaryKey: "PantheraGeneration") as? String)
            .flatMap(Generation.init(rawValue:))
    }
}
