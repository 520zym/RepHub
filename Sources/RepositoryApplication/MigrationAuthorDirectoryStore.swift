import Foundation
import Observation
import VersionControlCore

/// SVN 作者到 Git 作者的本机通讯录。记录以 SVN 服务端为范围，绝不保存地址中的账号或密码。
@MainActor
@Observable
public final class MigrationAuthorDirectoryStore {
    public struct Feedback: Equatable, Sendable {
        public enum Kind: Sendable, Equatable { case success, error }
        public let kind: Kind
        public let message: String
        public init(kind: Kind, message: String) { self.kind = kind; self.message = message }
    }

    public struct Record: Identifiable, Codable, Equatable, Sendable {
        public let scope: String
        public let source: String
        public var author: MigrationAuthor
        public var id: String { "\(scope)|\(source)" }
        public init(scope: String, source: String, author: MigrationAuthor) {
            self.scope = scope; self.source = source; self.author = author
        }
    }

    public struct EmailParts: Equatable, Sendable {
        public var localPart: String
        public var suffix: String
        public init(localPart: String, suffix: String) { self.localPart = localPart; self.suffix = suffix }
    }

    public enum DirectoryError: LocalizedError, Equatable {
        case invalidEmailSuffix
        case invalidAuthor
        case persistenceFailed

        public var errorDescription: String? {
            switch self {
            case .invalidEmailSuffix: "邮箱后缀应为域名，例如 example.com。"
            case .invalidAuthor: "作者名称或邮箱格式无效。"
            case .persistenceFailed: "无法保存作者通讯录，请检查本机存储空间后重试。"
            }
        }
    }

    private struct Document: Codable {
        var mappings: [String: [String: MigrationAuthor]]
        var emailSuffixes: [String]
        var defaultEmailSuffix: String
    }

    public static let defaultPersistenceKey = "rephub.migration.authorDirectory.v1"
    private static let placeholderSuffix = "authors.invalid"

    private let defaults: UserDefaults
    private let persistenceKey: String
    private var document: Document
    public private(set) var feedback: Feedback?

    public var emailSuffixes: [String] { document.emailSuffixes }
    public var defaultEmailSuffix: String { document.defaultEmailSuffix }
    public var records: [Record] {
        var values: [Record] = []
        for (scope, mappings) in document.mappings {
            for (source, author) in mappings {
                values.append(Record(scope: scope, source: source, author: author))
            }
        }
        return values.sorted { lhs, rhs in
            lhs.scope == rhs.scope ? lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending : lhs.scope < rhs.scope
        }
    }

    public init(defaults: UserDefaults = .standard, persistenceKey: String = MigrationAuthorDirectoryStore.defaultPersistenceKey) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.feedback = nil
        if let data = defaults.data(forKey: persistenceKey),
           let stored = try? JSONDecoder().decode(Document.self, from: data) {
            document = Self.normalized(document: stored)
        } else if defaults.data(forKey: persistenceKey) != nil {
            document = Document(mappings: [:], emailSuffixes: [Self.placeholderSuffix], defaultEmailSuffix: Self.placeholderSuffix)
            feedback = .init(kind: .error, message: "作者通讯录无法读取，已保留原始数据且暂未覆盖。")
        } else {
            document = Document(mappings: [:], emailSuffixes: [Self.placeholderSuffix], defaultEmailSuffix: Self.placeholderSuffix)
        }
    }

    /// 按来源服务端取回已保存映射；未保存的作者使用安全的名字和明确的占位域名。
    /// 此方法用于预检完成后的初始化，不会主动覆盖调用方已手工修改的映射。
    public func resolve(authors: [String: MigrationAuthor], sourceURL: String) -> [String: MigrationAuthor] {
        let scoped = document.mappings[Self.scope(for: sourceURL)] ?? [:]
        return authors.reduce(into: [:]) { result, item in
            let source = item.key
            let key = Self.sourceKey(source)
            let fallback = Self.defaultAuthor(source: source, existing: item.value, suffix: document.defaultEmailSuffix)
            result[source] = scoped[key].map { Self.defaultAuthor(source: source, existing: $0, suffix: document.defaultEmailSuffix) } ?? fallback
        }
    }

    /// 保存当前迁移计划中的全部作者映射，先完成编码再替换内存状态。
    public func save(authors: [String: MigrationAuthor], sourceURL: String) throws {
        let scope = Self.scope(for: sourceURL)
        var next = document
        var mappings = next.mappings[scope] ?? [:]
        for (source, author) in authors {
            mappings[Self.sourceKey(source)] = try validated(author, source: source)
        }
        next.mappings[scope] = mappings
        try persist(next)
        document = next
        feedback = .init(kind: .success, message: "已保存 \(mappings.count) 位作者到通讯录。")
    }

    public func update(source: String, sourceURL: String, author: MigrationAuthor) throws {
        try update(source: source, scope: Self.scope(for: sourceURL), author: author)
    }

    /// 用于通讯录管理页。scope 由 `records` 提供，避免将它再次误当作远程 URL。
    public func update(source: String, scope: String, author: MigrationAuthor) throws {
        var next = document
        var mappings = next.mappings[scope] ?? [:]
        mappings[Self.sourceKey(source)] = try validated(author, source: source)
        next.mappings[scope] = mappings
        try persist(next)
        document = next
        feedback = .init(kind: .success, message: "已更新 \(Self.safeName(source)) 的作者映射。")
    }

    public func remove(source: String, scope: String) throws {
        var next = document
        next.mappings[scope]?[Self.sourceKey(source)] = nil
        if next.mappings[scope]?.isEmpty == true { next.mappings[scope] = nil }
        try persist(next)
        document = next
        feedback = .init(kind: .success, message: "已删除作者映射。")
    }

    public func addEmailSuffix(_ value: String, makeDefault: Bool = false) throws {
        guard let suffix = Self.normalizedSuffix(value) else { try fail(.invalidEmailSuffix) }
        var next = document
        if !next.emailSuffixes.contains(suffix) { next.emailSuffixes.append(suffix); next.emailSuffixes.sort() }
        if makeDefault { next.defaultEmailSuffix = suffix }
        try persist(next)
        document = next
        feedback = .init(kind: .success, message: "已保存邮箱后缀 @\(suffix)。")
    }

    public func removeEmailSuffix(_ value: String) throws {
        guard let suffix = Self.normalizedSuffix(value), suffix != Self.placeholderSuffix else { try fail(.invalidEmailSuffix) }
        var next = document
        next.emailSuffixes.removeAll { $0 == suffix }
        if next.defaultEmailSuffix == suffix { next.defaultEmailSuffix = Self.placeholderSuffix }
        try persist(next)
        document = next
        feedback = .init(kind: .success, message: "已移除邮箱后缀 @\(suffix)。")
    }

    public func setDefaultEmailSuffix(_ value: String) throws {
        guard let suffix = Self.normalizedSuffix(value), document.emailSuffixes.contains(suffix) else { try fail(.invalidEmailSuffix) }
        var next = document
        next.defaultEmailSuffix = suffix
        try persist(next)
        document = next
        feedback = .init(kind: .success, message: "默认邮箱后缀已设为 @\(suffix)。")
    }

    /// 仅替换 `@authors.invalid`，或由调用方明确要求替换全部保存的邮箱后缀。
    @discardableResult
    public func applyDefaultSuffixToSavedAuthors(onlyPlaceholder: Bool) throws -> Int {
        let suffix = document.defaultEmailSuffix
        var next = document
        var changed = 0
        for scope in Array(next.mappings.keys) {
            guard let mapping = next.mappings[scope] else { continue }
            var revised = mapping
            for (source, author) in mapping {
                let parts = emailParts(for: author, source: source)
                guard !onlyPlaceholder || parts.suffix == Self.placeholderSuffix else { continue }
                let replacement = MigrationAuthor(name: author.name, email: "\(parts.localPart)@\(suffix)")
                guard replacement != author else { continue }
                revised[source] = replacement
                changed += 1
            }
            next.mappings[scope] = revised
        }
        try persist(next)
        document = next
        feedback = .init(kind: .success, message: changed == 0 ? "没有需要更新的保存邮箱。" : "已更新 \(changed) 位作者的邮箱后缀。")
        return changed
    }

    public func dismissFeedback() { feedback = nil }
    public func emailParts(for author: MigrationAuthor, source: String) -> EmailParts {
        let email = author.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = email.lastIndex(of: "@") else {
            // 编辑过程允许暂时未完成的邮箱，保存时再给出明确错误。
            return EmailParts(localPart: email, suffix: document.defaultEmailSuffix)
        }
        let local = String(email[..<at])
        let suffix = String(email[email.index(after: at)...]).lowercased()
        return EmailParts(localPart: local, suffix: Self.normalizedSuffix(suffix) ?? document.defaultEmailSuffix)
    }

    public func author(name: String, emailLocalPart: String, suffix: String, source: String) -> MigrationAuthor {
        let cleanName = Self.safeName(name.isEmpty ? source : name)
        let local = Self.safeEmailLocal(emailLocalPart.isEmpty ? cleanName : emailLocalPart)
        let domain = Self.normalizedSuffix(suffix) ?? document.defaultEmailSuffix
        return .init(name: cleanName, email: "\(local)@\(domain)")
    }

    public static func scope(for sourceURL: String) -> String {
        let input = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: input), let scheme = components.scheme?.lowercased() else {
            return "invalid:\(stableHash(input))"
        }
        if scheme == "file", let url = components.url {
            return "file://\(url.standardizedFileURL.path)"
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return "invalid:\(stableHash(input))" }
        let defaultPort: Int? = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        let port = components.port ?? defaultPort
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
    }

    private func persist(_ next: Document) throws {
        guard let data = try? JSONEncoder().encode(next) else { try fail(.persistenceFailed) }
        defaults.set(data, forKey: persistenceKey)
        guard defaults.data(forKey: persistenceKey) == data else { try fail(.persistenceFailed) }
    }

    private func fail(_ error: DirectoryError) throws -> Never {
        feedback = .init(kind: .error, message: error.localizedDescription)
        throw error
    }

    private func validated(_ author: MigrationAuthor, source: String) throws -> MigrationAuthor {
        let name = author.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard author.name == name, !name.isEmpty, !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }), !name.contains("<"), !name.contains(">") else { try fail(.invalidAuthor) }
        let email = author.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard author.email == email, pieces.count == 2, !pieces[0].isEmpty, Self.normalizedSuffix(pieces[1]) != nil,
              Self.safeEmailLocal(pieces[0]) == pieces[0], !email.contains("<"), !email.contains(">") else { try fail(.invalidAuthor) }
        return MigrationAuthor(name: name, email: email)
    }

    private static func normalized(document: Document) -> Document {
        let suffixes = Array(Set(document.emailSuffixes.compactMap(normalizedSuffix) + [placeholderSuffix])).sorted()
        let fallback = normalizedSuffix(document.defaultEmailSuffix).flatMap { suffixes.contains($0) ? $0 : nil } ?? placeholderSuffix
        var mappings: [String: [String: MigrationAuthor]] = [:]
        for (scope, values) in document.mappings where !scope.isEmpty {
            var normalized: [String: MigrationAuthor] = [:]
            for (key, value) in values {
                normalized[sourceKey(key)] = normalizedAuthor(value, source: key, suffix: fallback)
            }
            mappings[scope] = normalized
        }
        return Document(mappings: mappings, emailSuffixes: suffixes, defaultEmailSuffix: fallback)
    }

    private static func defaultAuthor(source: String, existing: MigrationAuthor, suffix: String) -> MigrationAuthor {
        let name = safeName(existing.name.isEmpty ? source : existing.name)
        let email = existing.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if pieces.count == 2, normalizedSuffix(pieces[1]) == placeholderSuffix {
            return MigrationAuthor(name: name, email: "\(safeEmailLocal(source))@\(suffix)")
        }
        return MigrationAuthor(name: name, email: email.isEmpty ? "\(safeEmailLocal(source))@\(suffix)" : email)
    }

    private static func normalizedAuthor(_ author: MigrationAuthor, source: String, suffix: String) -> MigrationAuthor {
        let name = safeName(author.name.isEmpty ? source : author.name)
        let pieces = author.email.split(separator: "@", maxSplits: 1).map(String.init)
        if pieces.count == 2, !pieces[0].isEmpty, normalizedSuffix(pieces[1]) != nil {
            return MigrationAuthor(name: name, email: "\(safeEmailLocal(pieces[0]))@\(pieces[1].lowercased())")
        }
        return MigrationAuthor(name: name, email: "\(safeEmailLocal(name))@\(suffix)")
    }

    private static func sourceKey(_ value: String) -> String {
        return value
    }

    private static func safeName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return "SVN 未知作者" }
        return String(trimmed.prefix(160))
    }

    private static func safeEmailLocal(_ value: String) -> String {
        let allowed = value.unicodeScalars.map { scalar -> Character? in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".!#$%&'*+/=?^_`{|}~-" )).contains(scalar) ? Character(String(scalar)) : "-"
        }.compactMap { $0 }
        let joined = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return joined.isEmpty ? "svn-unknown" : String(joined.prefix(64))
    }

    private static func normalizedSuffix(_ value: String) -> String? {
        let suffix = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard suffix.count <= 253, suffix.contains("."),
              suffix.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0) }),
              !suffix.hasPrefix("."), !suffix.hasSuffix("."), !suffix.contains("..") else { return nil }
        return suffix
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
