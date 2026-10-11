import Foundation

/// 为单次旧 TLS Subversion 调用生成的 OpenSSL 配置。
///
/// 它仅改变协议下限、套件安全级别和旧服务器重协商连接兼容性；证书链、主机名和
/// 有效期校验仍由 svn/serf 默认校验流程执行。
enum SVNTLSConfiguration {
    static func withLegacyCompatibleConfiguration<T: Sendable>(
        _ operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        let file = try makeLegacyCompatibleFile()
        defer { remove(file: file) }
        return try await operation(file)
    }

    static func makeLegacyCompatibleFile(fileManager: FileManager = .default) throws -> URL {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("rephub-svn-tls-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let file = folder.appendingPathComponent("openssl.cnf")
        let content = """
        openssl_conf = openssl_init

        [openssl_init]
        ssl_conf = ssl_configuration

        [ssl_configuration]
        system_default = rephub_svn_client

        [rephub_svn_client]
        MinProtocol = TLSv1
        MaxProtocol = TLSv1.3
        CipherString = DEFAULT:@SECLEVEL=0
        Options = UnsafeLegacyServerConnect
        """
        do {
            try Data(content.utf8).write(to: file, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return file
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    static func remove(file: URL, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: file.deletingLastPathComponent())
    }
}
