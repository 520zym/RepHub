import Foundation
import Observation

/// 工作区中按路径共享的展开状态。各视图只保存目录 ID，避免切换主/底部历史时丢失阅读位置。
@Observable
public final class WorkspaceTreeState {
    public var branchCollapsed: Set<String> = []
    public var revisionCollapsed: Set<String> = []
    public var workingCollapsed: Set<String> = []

    public init() {}
}

public struct PathTreeElement<Payload>: Identifiable {
    public let id: String
    public let path: String
    public let payload: Payload

    public init(id: String, path: String, payload: Payload) {
        self.id = id
        self.path = path
        self.payload = payload
    }
}

public struct PathTreeNode<Payload>: Identifiable {
    public let id: String
    public let title: String
    public let payload: Payload?
    public let children: [PathTreeNode]

    public var isDirectory: Bool { !children.isEmpty }
    public var directoryIDs: [String] {
        (isDirectory ? [id] : []) + children.flatMap(\.directoryIDs)
    }
}

/// 树行缩进必须保留真实深度。目录结构常超过五层，截断深度会让不同父级下的行看起来处于同一层。
enum TreeIndentation {
    static func leading(base: CGFloat, perDepth: CGFloat, depth: Int) -> CGFloat {
        base + CGFloat(max(0, depth)) * perDepth
    }
}

/// 将版本控制路径转成稳定的树。构建发生在输入变化时，渲染时只遍历已生成节点。
public enum PathTree {
    public static func make<Payload>(
        _ elements: [PathTreeElement<Payload>],
        namespace: String,
        separator: Character = "/"
    ) -> [PathTreeNode<Payload>] {
        build(elements, namespace: namespace, prefix: [], depth: 0, separator: separator)
    }

    private static func build<Payload>(
        _ elements: [PathTreeElement<Payload>],
        namespace: String,
        prefix: [Substring],
        depth: Int,
        separator: Character
    ) -> [PathTreeNode<Payload>] {
        let grouped = Dictionary(grouping: elements) { element -> Substring in
            let parts = element.path.split(separator: separator, omittingEmptySubsequences: true)
            return depth < parts.count ? parts[depth] : Substring(element.path)
        }

        return grouped.keys.sorted { String($0).localizedStandardCompare(String($1)) == .orderedAscending }.map { part in
            let members = grouped[part] ?? []
            let terminal = members.first { element in
                element.path.split(separator: separator, omittingEmptySubsequences: true).count == depth + 1
            }
            let nextPrefix = prefix + [part]
            let identifier = namespace + "/" + nextPrefix.map(String.init).joined(separator: "/")
            let descendants = members.filter { element in
                element.path.split(separator: separator, omittingEmptySubsequences: true).count > depth + 1
            }
            return PathTreeNode(
                id: identifier,
                title: String(part),
                payload: terminal?.payload,
                children: build(descendants, namespace: namespace, prefix: nextPrefix, depth: depth + 1, separator: separator)
            )
        }
    }
}
