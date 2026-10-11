import Foundation

struct PatchDisplayLine: Equatable {
    let text: String
    let oldLine: Int?
    let newLine: Int?
}

/// 为 unified diff 显示源文件和目标文件的真实行号；文件元数据与 hunk 标题不带行号。
enum PatchLineParser {
    static func parse(_ text: String) -> [PatchDisplayLine] {
        var oldLine: Int?
        var newLine: Int?
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine in
            let line = String(rawLine)
            if let range = hunkRange(line) {
                oldLine = range.old
                newLine = range.new
                return PatchDisplayLine(text: line, oldLine: nil, newLine: nil)
            }
            guard let old = oldLine, let new = newLine else {
                return PatchDisplayLine(text: line, oldLine: nil, newLine: nil)
            }
            if line.hasPrefix("+") && !line.hasPrefix("+++ ") {
                newLine = new + 1
                return PatchDisplayLine(text: line, oldLine: nil, newLine: new)
            }
            if line.hasPrefix("-") && !line.hasPrefix("--- ") {
                oldLine = old + 1
                return PatchDisplayLine(text: line, oldLine: old, newLine: nil)
            }
            if line.hasPrefix(" ") {
                oldLine = old + 1
                newLine = new + 1
                return PatchDisplayLine(text: line, oldLine: old, newLine: new)
            }
            // "\\ No newline at end of file" 等 hunk 注释不消耗源或目标行号。
            return PatchDisplayLine(text: line, oldLine: nil, newLine: nil)
        }
    }

    private static func hunkRange(_ line: String) -> (old: Int, new: Int)? {
        guard line.hasPrefix("@@ ") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count >= 3,
              let old = rangeStart(String(fields[1]), prefix: "-"),
              let new = rangeStart(String(fields[2]), prefix: "+") else { return nil }
        return (old, new)
    }

    private static func rangeStart(_ field: String, prefix: Character) -> Int? {
        guard field.first == prefix else { return nil }
        return Int(field.dropFirst().split(separator: ",", maxSplits: 1).first ?? "")
    }
}
