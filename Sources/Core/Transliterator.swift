import Foundation
import CoreFoundation

/// 拉丁化/归一化工具（FR-S2：拼音首字母命中中文应用名；X4：大小写/空格/全角不敏感）。
public enum Transliterator {

    /// 查询归一化：全角→半角、小写、折叠连续空白、去首尾空白。
    public static func normalize(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformFullwidthHalfwidth, false)
        CFStringTransform(m, nil, kCFStringTransformStripCombiningMarks, false)
        return (m as String)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "　" })
            .joined(separator: " ")
    }

    /// 中文 → 拉丁（无声调），逐字符转换：CJK 字符取拼音音节，非 CJK 原样小写。
    /// 返回 (全拼音节串, 首字母串)，例如「微信」→ ("weixin", "wx")、「GitHub」→ ("github", "github")。
    public static func pinyin(_ s: String) -> (full: String, initials: String) {
        var full: [String] = []
        var initials: [String] = []
        for ch in s {
            if isCJK(ch) {
                let syllable = romanize(ch)
                full.append(syllable)
                initials.append(String(syllable.prefix(1)))
            } else if ch.isLetter || ch.isNumber {
                let lower = String(ch).lowercased()
                full.append(lower)
                initials.append(lower)
            }
            // 空白与符号忽略（应用名中的破折号等）
        }
        return (full.joined(), initials.joined())
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        // CJK 统一表意 + 扩展A（常用汉字区间足够应用名场景）
        return (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
    }

    private static func romanize(_ ch: Character) -> String {
        let m = NSMutableString(string: String(ch))
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripCombiningMarks, false)
        return (m as String).lowercased()
    }
}
