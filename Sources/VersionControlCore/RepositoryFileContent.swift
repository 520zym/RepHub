import Foundation

/// 从指定历史节点读取普通文件的原始字节，不能回退到工作区或其他节点。
/// `nil` 仅表示该节点不存在此路径；认证、网络、格式及读取失败应抛出错误。
/// 具体工具的读取上限由适配器保留，界面不能把截断的二进制内容交给预览器。
/// `pegRevision` 是文件历史的追溯锚点；实际内容仍属于 `revision`，不能用锚点取代它。
public protocol RepositoryFileContentProvider: VersionControlProvider {
    func fileContent(in binding: RepositoryBinding, path: String, revision: String, pegRevision: String?) async throws -> Data?
}
