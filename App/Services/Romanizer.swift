import Foundation

/// Romanized lyrics: Japanese in romaji, Chinese in pinyin (with tone marks), Korean in
/// Revised Romanization. All on the device, with the system's own language data: the Japanese
/// tokenizer knows each word's reading, so kanji get their Japanese readings rather than
/// Chinese ones.
enum Romanizer {
    enum Script: Sendable {
        case japanese
        case chinese
        case korean
    }

    /// The script the lyrics need romanizing from, if any. Kana anywhere means Japanese (so
    /// lines of only kanji in a Japanese song still get Japanese readings).
    static func script(for lines: [String]) -> Script? {
        var hasHan = false
        var hasHangul = false
        for line in lines {
            for scalar in line.unicodeScalars {
                if isKana(scalar) { return .japanese }
                if isHan(scalar) { hasHan = true }
                if isHangul(scalar) { hasHangul = true }
            }
        }
        if hasHan { return .chinese }
        if hasHangul { return .korean }
        return nil
    }

    /// The line romanized, or nil when it has nothing to romanize (Latin text, symbols).
    static func romanize(_ line: String, as script: Script) -> String? {
        guard line.unicodeScalars.contains(where: { isKana($0) || isHan($0) || isHangul($0) }) else { return nil }
        let result: String?
        switch script {
        case .japanese:
            result = japanese(line)
        case .chinese, .korean:
            result = line.applyingTransform(.toLatin, reverse: false).map(latinPunctuation)
        }
        guard let text = result?.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces), !text.isEmpty, text != line else { return nil }
        return text
    }

    /// Word by word with the Japanese tokenizer's readings, keeping the punctuation and spaces
    /// between words, and a space between words that had none.
    private static func japanese(_ line: String) -> String? {
        let text = line as NSString
        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault, line as CFString,
                                                CFRangeMake(0, text.length),
                                                kCFStringTokenizerUnitWord,
                                                Locale(identifier: "ja_JP") as CFLocale)
        var output = ""
        var cursor = 0
        var lastWasWord = false
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location != kCFNotFound, range.location >= cursor else { continue }
            // What's between words: punctuation, spaces, symbols.
            let gap = text.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let word = text.substring(with: NSRange(location: range.location, length: range.length))
            let reading = (CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String)
                ?? word.applyingTransform(.toLatin, reverse: false)
                ?? word
            if !gap.isEmpty {
                output += latinPunctuation(gap)
            } else if lastWasWord {
                output += " "
            }
            output += reading
            lastWasWord = true
            cursor = range.location + range.length
        }
        if cursor < text.length {
            output += latinPunctuation(text.substring(from: cursor))
        }
        return output
    }

    /// 「、。！？」 and full-width spaces as their Latin equivalents.
    private static func latinPunctuation(_ text: String) -> String {
        let replaced = text
            .replacingOccurrences(of: "、", with: ", ")
            .replacingOccurrences(of: "。", with: ". ")
            .replacingOccurrences(of: "「", with: "\"")
            .replacingOccurrences(of: "」", with: "\"")
            .replacingOccurrences(of: "『", with: "\"")
            .replacingOccurrences(of: "』", with: "\"")
            .replacingOccurrences(of: "・", with: " ")
            .replacingOccurrences(of: "〜", with: "~")
            .replacingOccurrences(of: "\u{3000}", with: " ")
        // Full-width letters, digits and ！？，… as normal ones.
        return replaced.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? replaced
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true
        default: return false
        }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return true
        default: return false
        }
    }
}
