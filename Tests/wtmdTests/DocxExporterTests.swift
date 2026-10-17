import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 取包

/// 用系统的 `ditto` 解包——顺带验证 ZIP 结构与 CRC 真的没问题
/// （自己写的读取器验证自己写的写入器，等于什么也没验证）。
/// 注意别用 `unzip -p <part>`：`[Content_Types].xml` 里的方括号是它的通配符。
private func exportParts(_ markdown: String, baseURL: URL? = nil) throws -> (path: URL, dir: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-docx-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("export.docx")
    try DocxExporter.document(markdown: markdown, title: "测试文档", baseURL: baseURL).write(to: path)
    return (path, dir)
}

/// 解包到 `dir/unpacked`，返回该目录。
private func unpack(_ path: URL, into dir: URL) throws -> URL {
    let target = dir.appendingPathComponent("unpacked", isDirectory: true)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", path.path, target.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "DocxTest", code: Int(process.terminationStatus))
    }
    return target
}

private func part(_ name: String, in root: URL) throws -> String {
    try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
}

private func allParts(in root: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
        return []
    }
    // 枚举结果在 /private/var 下（/var 是符号链接），根路径也要先解析，否则截不干净
    let base = root.resolvingSymlinksInPath().path
    var names: [String] = []
    for case let url as URL in enumerator {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { continue }
        let path = url.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { continue }
        names.append(String(path.dropFirst(base.count + 1)))
    }
    return names
}

// MARK: - 包结构

/// 结构合法性：ZIP 能被标准工具解开，所有 XML 部件都能被 XMLDocument 解析。
@Test func exportedDocxIsAWellFormedPackage() throws {
    let (path, dir) = try exportParts("# 标题\n\n正文")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)

    let parts = allParts(in: root)
    for required in [
        "[Content_Types].xml",
        "_rels/.rels",
        "word/document.xml",
        "word/styles.xml",
        "word/numbering.xml",
        "word/_rels/document.xml.rels",
        "docProps/core.xml",
        "docProps/app.xml",
    ] {
        #expect(parts.contains(required))
    }

    for name in parts where name.hasSuffix(".xml") || name.hasSuffix(".rels") {
        let xml = try part(name, in: root)
        #expect(throws: Never.self) {
            _ = try XMLDocument(data: Data(xml.utf8))
        }
    }
}

@Test func headingsAndInlineFormattingBecomeRuns() throws {
    let markdown = """
    # 一级标题

    ## 二级标题

    正文里 **加粗**、*斜体*、~~删除~~、`代码` 都在。
    """
    let (path, dir) = try exportParts(markdown)
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)
    let document = try part("word/document.xml", in: root)

    #expect(document.contains("<w:pStyle w:val=\"Heading1\"/>"))
    #expect(document.contains("<w:pStyle w:val=\"Heading2\"/>"))
    #expect(document.contains("<w:b/>"))
    #expect(document.contains("<w:i/>"))
    #expect(document.contains("<w:strike/>"))
    #expect(document.contains("<w:rStyle w:val=\"CodeChar\"/>"))
    #expect(document.contains("加粗"))
}

@Test func linksBecomeExternalRelationships() throws {
    let (path, dir) = try exportParts("见 [wtmd 仓库](https://github.com/TonyMistark/wtmd)。")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)

    let document = try part("word/document.xml", in: root)
    let rels = try part("word/_rels/document.xml.rels", in: root)

    #expect(document.contains("<w:hyperlink r:id=\"rId"))
    #expect(document.contains("<w:rStyle w:val=\"Hyperlink\"/>"))
    #expect(rels.contains("Target=\"https://github.com/TonyMistark/wtmd\""))
    #expect(rels.contains("TargetMode=\"External\""))
}

@Test func tablesKeepAlignmentAndCellCount() throws {
    let markdown = """
    | 左 | 中 | 右 |
    | :--- | :---: | ---: |
    | a | b | c |
    """
    let (path, dir) = try exportParts(markdown)
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)
    let document = try part("word/document.xml", in: root)

    #expect(document.contains("<w:tbl>"))
    #expect(document.contains("<w:jc w:val=\"center\"/>"))
    #expect(document.contains("<w:jc w:val=\"right\"/>"))
    // 3 列 → 3 个 gridCol；表头 + 1 行 → 2 个 tr
    let gridColumns = document.components(separatedBy: "<w:gridCol").count - 1
    let rows = document.components(separatedBy: "<w:tr>").count - 1
    #expect(gridColumns == 3)
    #expect(rows == 2)
    #expect(document.contains("<w:tblHeader/>"))
}

/// 列表走 Word 的编号定义（无序 numId=1、有序 numId=2）。
///
/// 缩进项在解析阶段就被拍平成同级（与预览渲染一致，解析器不做嵌套），
/// 所以这里刻意**不**断言 `ilvl > 0`——导出应当与预览所见一致，
/// 而不是比预览多出一层结构。
@Test func listsUseNumbering() throws {
    let markdown = """
    - 第一项
    - 第二项
        - 缩进项

    1. 有序一
    2. 有序二
    """
    let (path, dir) = try exportParts(markdown)
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)
    let document = try part("word/document.xml", in: root)

    #expect(document.contains("<w:numId w:val=\"1\"/>"))
    #expect(document.contains("<w:numId w:val=\"2\"/>"))
    #expect(document.contains("<w:pStyle w:val=\"ListParagraph\"/>"))
    #expect(!document.contains("<w:ilvl w:val=\"1\"/>"))
}

@Test func codeBlocksKeepLineBreaksAndEscapeMarkup() throws {
    let markdown = """
    ```swift
    let a = 1 < 2
    print("& done")
    ```
    """
    let (path, dir) = try exportParts(markdown)
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)
    let document = try part("word/document.xml", in: root)

    #expect(document.contains("<w:pStyle w:val=\"CodeBlock\"/>"))
    #expect(document.contains("<w:br/>"))
    #expect(document.contains("let a = 1 &lt; 2"))
    #expect(document.contains("print(&quot;&amp; done&quot;)"))
}

@Test func localImagesAreEmbeddedAsMedia() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-docx-img-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // 16×16 的纯色 PNG
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 16, height: 16).fill()
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: dir.appendingPathComponent("pic.png"))

    let (path, exportDir) = try exportParts("![示意图](pic.png)", baseURL: dir)
    defer { try? FileManager.default.removeItem(at: exportDir) }
    let root = try unpack(path, into: exportDir)

    #expect(allParts(in: root).contains("word/media/image1.png"))
    let document = try part("word/document.xml", in: root)
    #expect(document.contains("<a:blip r:embed=\""))
    #expect(document.contains("<wp:extent"))

    // 图片关系必须是内部关系（不能是 TargetMode="External"）
    let rels = try part("word/_rels/document.xml.rels", in: root)
    #expect(rels.contains("Target=\"media/image1.png\""))
    #expect(!rels.contains("Target=\"media/image1.png\" TargetMode"))
}

/// 图片找不到时不能把这一段吞掉：退回 alt 文本，读者知道这里原本有图。
@Test func missingImageFallsBackToAltText() throws {
    let (path, dir) = try exportParts("![缺失的图](nope.png)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)
    let document = try part("word/document.xml", in: root)

    #expect(document.contains("[缺失的图]"))
    #expect(!document.contains("<a:blip"))
}

/// 正文里的 `& < > "` 必须转义：少转一个，整份 document.xml 就不再是合法 XML，
/// Word 会直接报「文件已损坏」。
@Test func paragraphTextIsXMLEscaped() throws {
    let markdown = "5 & 3 < 7 > 2，引号 \"q\" 与 'a' 都要转义。"
    let (path, dir) = try exportParts(markdown)
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)
    let document = try part("word/document.xml", in: root)

    #expect(document.contains("5 &amp; 3 &lt; 7 &gt; 2"))
    #expect(document.contains("&quot;q&quot;"))
    #expect(document.contains("&apos;a&apos;"))
    // 再确认一次：转义之后整份 XML 仍然可解析
    #expect(throws: Never.self) {
        _ = try XMLDocument(data: Data(document.utf8))
    }
}

@Test func tocPlaceholderIsSkippedAndMathStaysLiteral() throws {
    let (path, dir) = try exportParts("[TOC]\n\n# 章\n\n行内 $E=mc^2$ 公式")
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try unpack(path, into: dir)
    let document = try part("word/document.xml", in: root)

    #expect(!document.contains("wtmd-toc"))
    #expect(document.contains("$E=mc^2$"))
}

// MARK: - 内联解析（导出的地基）

@Test func inlineParserNestsBoldAndItalic() {
    let runs = DocxInline.runs("**粗 *斜* 粗**")
    #expect(runs.contains { $0.bold && !$0.italic && $0.content == .text("粗 ") })
    #expect(runs.contains { $0.bold && $0.italic && $0.content == .text("斜") })
}

@Test func inlineParserKeepsCodeVerbatim() {
    let runs = DocxInline.runs("`**not bold**`")
    #expect(runs.count == 1)
    #expect(runs[0].code)
    #expect(runs[0].content == .text("**not bold**"))
}

@Test func inlineParserHonoursBackslashEscapes() {
    let runs = DocxInline.runs("\\*不是斜体\\*")
    #expect(runs.count == 1)
    #expect(runs[0].content == .text("*不是斜体*"))
    #expect(!runs[0].italic)
}

@Test func inlineParserFindsBareURLs() {
    let runs = DocxInline.runs("见 https://example.com/x 这里")
    #expect(runs.contains { $0.link == "https://example.com/x" })
}
