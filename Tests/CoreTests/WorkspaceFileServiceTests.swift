import Foundation
import Testing
import RepositoryApplication

@Suite("工作区文件服务")
struct WorkspaceFileServiceTests {
    @Test("按层读取文件并保留隐藏与忽略文件，过滤版本控制元数据")
    func listsOnlyOneLevelWithoutMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("normal\n", path: "normal.txt")
        try fixture.write("hidden\n", path: ".hidden")
        try fixture.write("ignored\n", path: "ignored.tmp")
        try fixture.write("nested\n", path: "folder/nested.txt")
        try fixture.makeDirectory(".git")
        try fixture.makeDirectory(".svn")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("link-to-folder"),
            withDestinationURL: fixture.root.appendingPathComponent("folder")
        )

        let service = WorkspaceFileService()
        let entries = try await service.children(in: fixture.root)
        #expect(entries.first?.name == "folder")
        #expect(entries.map(\.name).sorted() == [".hidden", "folder", "ignored.tmp", "link-to-folder", "normal.txt"])
        #expect(entries.first { $0.name == "link-to-folder" }?.isDirectory == false)
        #expect(entries.first { $0.name == "link-to-folder" }?.isSymbolicLink == true)

        let nested = try await service.children(in: fixture.root, path: "folder")
        #expect(nested.map(\.path) == ["folder/nested.txt"])
    }

    @Test("目录路径不能越出根目录，也不跟随符号链接")
    func rejectsTraversalAndSymbolicLinks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeDirectory("folder")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("link"),
            withDestinationURL: fixture.root.appendingPathComponent("folder")
        )
        let service = WorkspaceFileService()

        do {
            _ = try await service.children(in: fixture.root, path: "../outside")
            Issue.record("目录遍历路径不应被读取。")
        } catch { }
        do {
            _ = try await service.children(in: fixture.root, path: "link")
            Issue.record("符号链接不应被展开。")
        } catch { }
        let preview = try await service.preview(in: fixture.root, path: "link")
        #expect(preview.text == nil)
        #expect(preview.message == "符号链接不提供预览。")
    }

    @Test("预览限制大小并清晰标记二进制和非 UTF-8 文件")
    func previewsTextWithBoundedReads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("中文文本\n", path: "text.txt")
        try fixture.write(Data([0x00, 0x01]), path: "binary.dat")
        try fixture.write(Data([0xff, 0xfe]), path: "invalid.txt")
        try fixture.write(Data(repeating: 0x61, count: WorkspaceFileService.previewLimit + 64), path: "large.txt")
        let service = WorkspaceFileService()

        let text = try await service.preview(in: fixture.root, path: "text.txt")
        #expect(text.text == "中文文本\n")
        #expect(text.message == nil)
        let binary = try await service.preview(in: fixture.root, path: "binary.dat")
        #expect(binary.text == nil)
        #expect(binary.message?.contains("二进制") == true)
        let invalid = try await service.preview(in: fixture.root, path: "invalid.txt")
        #expect(invalid.text == nil)
        #expect(invalid.message?.contains("UTF-8") == true)
        let large = try await service.preview(in: fixture.root, path: "large.txt")
        #expect(large.isTruncated)
        #expect(large.text?.count == WorkspaceFileService.previewLimit)
        #expect(large.message?.contains("1 MiB") == true)
    }

    @Test("常见办公文档仅返回已校验的系统预览地址")
    func providesSystemPreviewDescriptorForSupportedDocuments() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data([0x50, 0x4b, 0x03, 0x04]), path: "资料/方案.docx")
        try fixture.write(Data([0x25, 0x50, 0x44, 0x46]), path: "资料/说明.pdf")
        try fixture.write(Data([0x50, 0x4b, 0x03, 0x04]), path: "资料/预算.xlsx")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("资料/链接.pdf"),
            withDestinationURL: fixture.root.appendingPathComponent("资料/说明.pdf")
        )
        let service = WorkspaceFileService()

        let word = try await service.preview(in: fixture.root, path: "资料/方案.docx")
        #expect(word.documentKind == .word)
        #expect(word.systemPreviewURL == fixture.root.appendingPathComponent("资料/方案.docx").standardizedFileURL)
        let pdf = try await service.preview(in: fixture.root, path: "资料/说明.pdf")
        #expect(pdf.documentKind == .pdf)
        #expect(pdf.systemPreviewURL == fixture.root.appendingPathComponent("资料/说明.pdf").standardizedFileURL)
        let sheet = try await service.preview(in: fixture.root, path: "资料/预算.xlsx")
        #expect(sheet.documentKind == .spreadsheet)
        #expect(sheet.systemPreviewURL != nil)

        let link = try await service.preview(in: fixture.root, path: "资料/链接.pdf")
        #expect(link.systemPreviewURL == nil)
        #expect(link.documentKind == nil)
    }

    @Test("过大的文档不会交给系统预览")
    func rejectsOversizedSystemPreview() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("archive.pdf")
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(WorkspaceFileService.systemPreviewFileSizeLimit + 1))
        try handle.close()
        let preview = try await WorkspaceFileService().preview(in: fixture.root, path: "archive.pdf")
        #expect(preview.documentKind == .pdf)
        #expect(preview.systemPreviewURL == nil)
        #expect(preview.message?.contains("256 MiB") == true)
    }

    @Test("外部编辑只返回工作副本内普通文件，拒绝链接和元数据")
    func externalEditingKeepsWorkspaceBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("resolved\n", path: "Sources/File.swift")
        try fixture.write("metadata\n", path: ".git/config")
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("link"),
                                                   withDestinationURL: fixture.root.appendingPathComponent("Sources/File.swift"))
        let service = WorkspaceFileService()
        let url = try await service.editableFileURL(in: fixture.root, path: "Sources/File.swift")
        #expect(url == fixture.root.appendingPathComponent("Sources/File.swift").resolvingSymlinksInPath())
        for path in ["link", ".git/config", "../outside", "Sources"] {
            do {
                _ = try await service.editableFileURL(in: fixture.root, path: path)
                Issue.record("不应把此路径交给外部编辑器：\(path)")
            } catch { }
        }
    }

    private final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("RepHub-WorkspaceFiles-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func write(_ text: String, path: String) throws {
            try write(Data(text.utf8), path: path)
        }

        func write(_ data: Data, path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func makeDirectory(_ path: String) throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
