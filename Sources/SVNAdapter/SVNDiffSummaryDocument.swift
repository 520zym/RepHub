import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import VersionControlCore

/// 只解析 `svn diff --summarize --xml` 的路径清单，避免依赖本地化的文本列宽。
final class SVNDiffSummaryDocument: NSObject, XMLParserDelegate {
    struct Entry {
        let path: String
        let item: String
        let kind: String
    }

    private(set) var entries: [Entry] = []
    private var item: String?
    private var kind: String?
    private var text = ""

    init(data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else {
            throw VersionControlError.invalidData(parser.parserError?.localizedDescription ?? "svn 差异摘要 XML 无法解析。")
        }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "path" {
            item = attributeDict["item"]
            kind = attributeDict["kind"] ?? ""
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard elementName == "path", let item else { return }
        entries.append(Entry(path: text.trimmingCharacters(in: .whitespacesAndNewlines), item: item, kind: kind ?? ""))
        self.item = nil
        kind = nil
        text = ""
    }
}
