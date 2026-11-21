// Adapted from Panthera Speech. See third_party/panthera/LICENSE.
import Foundation

/// Text as the engine reads it: MacRoman, not UTF-8. A port of
/// MacRoman.kt / synthDrivers/_panthera/text.py, which were arrived at by ear;
/// every fold below is a reported bug. The base table is Foundation's own
/// `.macOSRoman`, which is Apple's, and so is the engine.
public enum MacRoman {
    /// Characters MacRoman has no room for, mapped to something it can say.
    static let fold: [UInt32: String] = [
        0x00A0: " ", 0x2007: " ", 0x2009: " ", 0x202F: " ",           // fixed spaces
        0x2011: "-", 0x2012: "-", 0x2015: "-", 0x2212: "-",           // more dashes
        0x2032: "'", 0x2033: "\"", 0x02BC: "'",                       // primes
        // MacRoman has the curly apostrophe, but at the right single
        // QUOTATION mark, and the engine breaks the phrase there.
        0x2018: "'", 0x2019: "'",
        0x2044: "/",                                                  // fraction slash
        0x0151: "ö", 0x0150: "Ö", 0x0171: "ü", 0x0170: "Ü",           // Hungarian long vowels
        0x0141: "L", 0x0142: "l", 0x0110: "D", 0x0111: "d",           // strokes survive NFD
    ]

    /// One scalar's byte, or nil if MacRoman cannot spell it.
    static func direct(_ s: Unicode.Scalar) -> UInt8? {
        if s.value < 0x80 { return UInt8(s.value) }
        guard let data = String(Character(s)).data(using: .macOSRoman, allowLossyConversion: false),
              data.count == 1 else { return nil }
        return data.first
    }

    /// -> the engine's bytes, NUL-terminated for the C API.
    ///
    /// Anything MacRoman cannot spell loses its accent, or becomes a space --
    /// never "?", which the engine reads as a question and lifts the whole
    /// sentence for.
    public static func encode(_ text: String) -> [CChar] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + 1)
        for scalar in text.unicodeScalars {
            if let folded = fold[scalar.value] {
                for f in folded.unicodeScalars { out.append(direct(f) ?? 0x20) }
                continue
            }
            if let b = direct(scalar) { out.append(b == 0 ? 0x20 : b); continue }
            let bare = String(Character(scalar)).decomposedStringWithCanonicalMapping.unicodeScalars
                .filter { $0.properties.generalCategory != .nonspacingMark }
            var wrote = false
            for b in bare { if let byte = direct(b), byte != 0 { out.append(byte); wrote = true } }
            if !wrote { out.append(0x20) }
        }
        out.append(0)
        return out.map { CChar(bitPattern: $0) }
    }
}
