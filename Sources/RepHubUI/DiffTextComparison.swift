import Foundation

/// 差异阅读的纯文本比较工具。仅服务于显示层，永不改变原始补丁内容。
enum DiffTextComparison {
    struct InlineChanges: Sendable, Equatable {
        let oldRanges: [Range<Int>]
        let newRanges: [Range<Int>]
        let isWhitespaceOnly: Bool
        let usedFallback: Bool
    }

    /// 控制字符级计算的上限，避免非常长的生成文件使阅读界面退化。
    static let maximumComparableCharacters = 8_192

    static func compare(old: String, new: String) -> InlineChanges {
        let oldCharacters = Array(old)
        let newCharacters = Array(new)
        let whitespaceOnly = normalizedWhitespace(old) == normalizedWhitespace(new) && old != new
        guard old != new else {
            return InlineChanges(oldRanges: [], newRanges: [], isWhitespaceOnly: false, usedFallback: false)
        }
        guard oldCharacters.count <= maximumComparableCharacters,
              newCharacters.count <= maximumComparableCharacters else {
            return InlineChanges(
                oldRanges: oldCharacters.isEmpty ? [] : [0..<oldCharacters.count],
                newRanges: newCharacters.isEmpty ? [] : [0..<newCharacters.count],
                isWhitespaceOnly: whitespaceOnly,
                usedFallback: true
            )
        }

        var prefix = 0
        while prefix < oldCharacters.count, prefix < newCharacters.count,
              oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        var oldEnd = oldCharacters.count
        var newEnd = newCharacters.count
        while oldEnd > prefix, newEnd > prefix,
              oldCharacters[oldEnd - 1] == newCharacters[newEnd - 1] {
            oldEnd -= 1
            newEnd -= 1
        }
        return InlineChanges(
            oldRanges: prefix == oldEnd ? [] : [prefix..<oldEnd],
            newRanges: prefix == newEnd ? [] : [prefix..<newEnd],
            isWhitespaceOnly: whitespaceOnly,
            usedFallback: false
        )
    }

    static func normalizedWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
