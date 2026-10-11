import Foundation

/// 命令输出与操作记录的显示边界；不要把连接 URL 内的认证信息写入界面或日志。
public enum RepositoryDisplaySanitizer {
    public static func redact(_ text: String) -> String {
        text.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://)[^\s/@]+@"#, with: "$1***@", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)([?&](?:access_token|token|api_key|password)=)[^\s&#]+"#, with: "$1***", options: .regularExpression)
    }
}
