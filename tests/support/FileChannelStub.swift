import AudioToolbox
import Foundation

/// Test stand-in for Synth/FileChannel.swift. The real channel opens the
/// extension's own container store, which exists only inside an .appex; a
/// test process that instantiates ClassicVoicesAudioUnit directly has none.
/// Speech requests never use the channel.
final class FileChannel: NSObject, AUMessageChannel {
    var callHostBlock: CallHostBlock?
    func callAudioUnit(_ message: [AnyHashable: Any]) -> [AnyHashable: Any] { [:] }
}
