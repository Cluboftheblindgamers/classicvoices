// Panthera regression corpus; see third_party/panthera/LICENSE.
import Foundation
@testable import ClassicPortTest

@main struct PronunciationScopeCheck {
    static func main() throws {
        let alex = "com.pantheraspeech.snowleopard.alex"
        let victoria = "com.pantheraspeech.snowleopard.victoria"
        let otherAlex = "com.pantheraspeech.leopard.alex"
        let legacy = try JSONDecoder().decode(Pronunciation.self, from: Data("""
        {"match":"Alpha","replacement":"Beta","generations":["snowleopard"]}
        """.utf8))
        precondition(legacy.voiceIDs == nil)
        precondition(legacy.applies(to: .snowleopard, voiceID: alex))
        precondition(legacy.applies(to: .snowleopard, voiceID: victoria))
        precondition(!legacy.applies(to: .leopard, voiceID: otherAlex))

        var scoped = legacy
        scoped.voiceIDs = [alex]
        precondition(scoped.applies(to: .snowleopard, voiceID: alex))
        precondition(scoped.applies(to: .snowleopard, voiceID: "com.example.extension." + alex))
        precondition(!scoped.applies(to: .snowleopard, voiceID: victoria))
        precondition(!scoped.applies(to: .leopard, voiceID: otherAlex))
        precondition(!scoped.applies(to: .leopard, voiceID: alex))
        precondition(!scoped.applies(to: .snowleopard))
        precondition(!scoped.applies(to: .snowleopard, voiceID: "unrelated" + alex))
        precondition(Pronunciations.apply([scoped], to: "Alpha", generation: .snowleopard, voiceID: alex) == [.text("Beta")])
        precondition(Pronunciations.apply([scoped], to: "Alpha", generation: .snowleopard, voiceID: victoria) == [.text("Alpha")])
        let general = Pronunciation(match: "Alpha", replacement: "General")
        precondition(Pronunciations.apply([general, scoped], to: "Alpha", generation: .snowleopard, voiceID: alex) == [.text("Beta")])
        precondition(Pronunciations.apply([scoped, general], to: "Alpha", generation: .snowleopard, voiceID: victoria) == [.text("General")])

        // A voice scope is independent of the last-used generation checklist.
        scoped.generations = [.tiger]
        precondition(scoped.applies(to: .snowleopard, voiceID: alex))
        let decoded = try JSONDecoder().decode(Pronunciation.self, from: JSONEncoder().encode(scoped))
        precondition(decoded == scoped)
        let suite = "com.pantheraspeech.scope-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        Pronunciations.save([scoped], to: defaults)
        precondition(Pronunciations.load(from: defaults) == [scoped])
        scoped.voiceIDs = []
        precondition(!scoped.applies(to: .snowleopard, voiceID: alex))
        precondition(Pronunciations.apply([scoped], to: "Alpha", generation: .snowleopard, voiceID: alex) == [.text("Alpha")])
        let emptyRoundTrip = try JSONDecoder().decode(Pronunciation.self, from: JSONEncoder().encode(scoped))
        precondition(emptyRoundTrip.voiceIDs == [])
        scoped.voiceIDs = nil
        precondition(scoped.applies(to: .tiger))
        precondition(!scoped.applies(to: .snowleopard, voiceID: alex))
        scoped.generations = []
        precondition(scoped.applies(to: .snowleopard, voiceID: victoria))
        print("PASS pronunciation scopes: legacy, generations, exact voices, prefixed IDs, no selection, persistence and scope switching")
    }
}
