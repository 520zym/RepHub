import Foundation

enum DiffSideKind: Equatable {
    case context, added, removed
}

struct DiffSideLine: Equatable {
    let number: Int?
    let text: String
    let kind: DiffSideKind
}

enum DiffRow: Equatable {
    case metadata(String, isHunk: Bool)
    case paired(old: DiffSideLine?, new: DiffSideLine?)
}

/// 不修改已有 `PatchLineParser`，供并排差异区按 hunk 对齐左右行。
enum SideBySideDiffParser {
    static func parse(_ patch: String) -> [DiffRow] {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rows: [DiffRow] = []
        var oldLine: Int?
        var newLine: Int?
        var oldRemaining: Int?
        var newRemaining: Int?
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if let range = hunkRange(line) {
                oldLine = range.old
                newLine = range.new
                oldRemaining = range.oldCount
                newRemaining = range.newCount
                rows.append(.metadata(line, isHunk: true))
                index += 1
                continue
            }
            guard oldLine != nil, newLine != nil, oldRemaining != nil, newRemaining != nil else {
                rows.append(.metadata(line, isHunk: false))
                index += 1
                continue
            }
            if line.hasPrefix(" ") && oldRemaining! > 0 && newRemaining! > 0 {
                rows.append(.paired(
                    old: DiffSideLine(number: displayNumber(oldLine), text: String(line.dropFirst()), kind: .context),
                    new: DiffSideLine(number: displayNumber(newLine), text: String(line.dropFirst()), kind: .context)
                ))
                oldLine! += 1; newLine! += 1
                oldRemaining! -= 1; newRemaining! -= 1
                index += 1
                continue
            }
            if (line.hasPrefix("-") && oldRemaining! > 0) || (line.hasPrefix("+") && newRemaining! > 0) {
                var removals: [DiffSideLine] = []
                var additions: [DiffSideLine] = []
                while index < lines.count {
                    let change = lines[index]
                    if change.hasPrefix("-") && oldRemaining! > 0 {
                        removals.append(DiffSideLine(number: displayNumber(oldLine), text: String(change.dropFirst()), kind: .removed))
                        oldLine! += 1
                        oldRemaining! -= 1
                    } else if change.hasPrefix("+") && newRemaining! > 0 {
                        additions.append(DiffSideLine(number: displayNumber(newLine), text: String(change.dropFirst()), kind: .added))
                        newLine! += 1
                        newRemaining! -= 1
                    } else { break }
                    index += 1
                }
                for offset in 0..<max(removals.count, additions.count) {
                    rows.append(.paired(old: removals.indices.contains(offset) ? removals[offset] : nil, new: additions.indices.contains(offset) ? additions[offset] : nil))
                }
                continue
            }
            // 二进制提示、无换行标记等不会消耗 hunk 行号。
            rows.append(.metadata(line, isHunk: false))
            index += 1
        }
        return rows
    }

    private static func hunkRange(_ line: String) -> (old: Int, oldCount: Int, new: Int, newCount: Int)? {
        guard line.hasPrefix("@@ ") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 3,
              let old = range(of: fields[1], prefix: "-"),
              let new = range(of: fields[2], prefix: "+") else { return nil }
        return (old.start, old.count, new.start, new.count)
    }

    private static func range(of field: Substring, prefix: Character) -> (start: Int, count: Int)? {
        guard field.first == prefix else { return nil }
        let values = field.dropFirst().split(separator: ",", maxSplits: 1)
        guard let start = Int(values.first ?? "") else { return nil }
        return (start, values.count == 2 ? Int(values[1]) ?? 1 : 1)
    }

    private static func displayNumber(_ number: Int?) -> Int? {
        guard let number, number > 0 else { return nil }
        return number
    }

}
