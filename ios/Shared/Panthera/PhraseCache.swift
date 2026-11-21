// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Dispatch
import Foundation

/// Recently spoken pieces, as the engine rendered them, so a repeat is
/// heard at once instead of waiting for the engine again.
///
/// VoiceOver repeats itself constantly -- window titles, button names, the
/// same row as you move back over it -- and the slow case for this engine is
/// exactly a name it does not know ("Panthera" costs about 0.3 s on an M-series
/// Mac, all of it the 10.6 engine working out a pronunciation in emulated
/// code).  The engine is deterministic for the same text, voice, rate, pitch
/// and settings, so its output can simply be kept.
///
/// One per process (`shared`), not one per audio unit: the system makes a new
/// unit when it resumes a voice it suspended at lock, which used to start an
/// empty cache beside the old one -- twice the memory, and nothing remembered.
/// Under memory pressure it gives up what it holds (a warning halves it, a
/// critical one empties it): it is only ever a shortcut.
final class PhraseCache: @unchecked Sendable {
    static let shared = PhraseCache(budgetSeconds: 90, longestSeconds: 10,
                                    sampleRate: 22050)

    private struct Entry { var pcm: [Float]; var used: UInt64 }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var samples = 0
    private let budget: Int                   // total samples kept
    let longest: Int                          // longest piece worth keeping
    private var pressure: DispatchSourceMemoryPressure?

    init(budgetSeconds: Double, longestSeconds: Double, sampleRate: Double) {
        budget = Int(budgetSeconds * sampleRate)
        longest = Int(longestSeconds * sampleRate)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical],
                                                             queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.shrink(to: source.data.contains(.critical) ? 0 : self.budget / 2)
        }
        source.resume()
        pressure = source
    }

    deinit { pressure?.cancel() }

    func get(_ key: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        guard var hit = entries[key] else { return nil }
        clock &+= 1
        hit.used = clock
        entries[key] = hit
        return hit.pcm
    }

    func put(_ key: String, _ pcm: [Float]) {
        guard !pcm.isEmpty, pcm.count <= longest else { return }
        lock.lock(); defer { lock.unlock() }
        clock &+= 1
        if let old = entries.updateValue(Entry(pcm: pcm, used: clock), forKey: key) {
            samples -= old.pcm.count
        }
        samples += pcm.count
        if samples > budget { evict(to: budget * 3 / 4) }
    }

    /// Down to `limit` samples, least recently used first.
    func shrink(to limit: Int) {
        lock.lock(); defer { lock.unlock() }
        evict(to: limit)
    }

    /// Caller holds the lock.  Evicting a quarter at a time keeps this sort
    /// rare: one in every few dozen insertions once the cache is full.
    private func evict(to limit: Int) {
        guard samples > limit else { return }
        if limit <= 0 {
            entries.removeAll(keepingCapacity: false)
            samples = 0
            return
        }
        for (key, e) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            if samples <= limit { break }
            entries.removeValue(forKey: key)
            samples -= e.pcm.count
        }
    }
}
