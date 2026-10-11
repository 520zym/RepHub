import CryptoKit
import Foundation
import VersionControlCore

/// 适配器复核待提交内容使用的流式指纹。不跟随路径父级符号链接，也不读取版本管理元数据。
public enum CommitFileSnapshot {
    public static func fingerprint(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func validatedURL(root: URL, path: String) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard root.isFileURL, !path.isEmpty, !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && ![".git", ".svn"].contains($0.lowercased()) }) else {
            throw VersionControlError.invalidRepository("提交路径必须位于工作副本内，不能包含版本管理元数据。")
        }
        var current = root.standardizedFileURL.resolvingSymlinksInPath()
        for part in parts.dropLast() {
            current.appendPathComponent(String(part))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw VersionControlError.unsupported("提交路径经过符号链接目录，请直接打开真实工作副本：\(path)")
            }
        }
        return root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(path)
    }

    public static func fingerprint(root: URL, path: String) throws -> String {
        let url = try validatedURL(root: root, path: path)
        let files = FileManager.default
        let before: [FileAttributeKey: Any]
        do { before = try files.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return "missing" }
        let type = before[.type] as? FileAttributeType
        var hash = SHA256()
        hash.update(data: Data("\(type?.rawValue ?? "unknown"):\(before[.posixPermissions] ?? 0)\n".utf8))
        switch type {
        case .typeRegular:
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 128 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        case .typeSymbolicLink:
            hash.update(data: Data(try files.destinationOfSymbolicLink(atPath: url.path).utf8))
        case .typeDirectory: break
        default: throw VersionControlError.unsupported("暂不支持提交该文件类型：\(path)")
        }
        let after = try files.attributesOfItem(atPath: url.path)
        for key in [FileAttributeKey.type, .size, .modificationDate, .posixPermissions, .systemFileNumber] {
            guard String(describing: before[key]) == String(describing: after[key]) else {
                throw VersionControlError.invalidRepository("读取期间文件发生变化，请重新准备提交：\(path)")
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
