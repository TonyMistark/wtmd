import AppKit
import Foundation
import WTMarkdownKit

/// Markdown → Word (.docx)。
///
/// 自研 OOXML 打包，零第三方依赖：一个 ZIP 容器 + 几个 XML 部件。
/// 覆盖：标题 1–6、段落、粗体/斜体/删除线/行内代码、链接、图片、无序/有序列表
/// （含嵌套与任务项）、引用、围栏代码块、GFM 表格（含对齐）、分隔线。
///
/// 已知取舍（都在帮助文本与文档里写明）：
/// - `$…$` 数学、Mermaid 图输出为原文/代码，不做图形化（Word 里那是域或图片，得另做）
/// - `[^1]` 脚注保留为原文：解析器把定义行收进了内部状态，导出侧拿不到
/// - `[TOC]` 不生成：Word 的目录应当是域（可更新），凭空写死一份反而误导
enum DocxExporter {
    static func document(markdown: String, title: String, baseURL: URL?) -> Data {
        DocxPackage(title: title, baseURL: baseURL).build(markdown: markdown)
    }
}

// MARK: - 打包

private final class DocxPackage {
    private let title: String
    private let baseURL: URL?

    private var relationships: [(id: String, type: String, target: String, external: Bool)] = []
    private var media: [(path: String, data: Data)] = []
    private var imageIDs: [String: String] = [:]
    private var hyperlinks: [String: String] = [:]
    private var nextRelID = 1
    private var nextDocPrID = 1

    /// 版心宽度（twips）：A4 宽 11906 减左右各 1440。
    private static let textWidth = 9026
    /// 版心宽度（pt），图片超过它就要缩放。
    private static let textWidthPoints: CGFloat = 451
    private static let emuPerPoint: CGFloat = 12_700

    private let imageType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    private let hyperlinkType = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"

    init(title: String, baseURL: URL?) {
        self.title = title
        self.baseURL = baseURL
    }

    func build(markdown: String) -> Data {
        let blocks = MarkdownParser().parse(markdown)
        var body = blocks.map { render($0) }.joined()
        // 表格/代码块贴着 sectPr 时部分阅读器会丢段间距，末尾补一个空段
        body += "<w:p/>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypesXML())
        zip.add("_rels/.rels", packageRelationshipsXML())
        zip.add("docProps/core.xml", corePropertiesXML())
        zip.add("docProps/app.xml", appPropertiesXML())
        zip.add("word/document.xml", documentXML(body: body))
        zip.add("word/styles.xml", stylesXML())
        zip.add("word/numbering.xml", numberingXML())
        zip.add("word/_rels/document.xml.rels", documentRelationshipsXML())
        for item in media {
            zip.add(item.path, item.data)
        }
        return zip.finish()
    }

    // MARK: - 块

    private func render(_ block: Block, listDepth: Int = 0, quoteDepth: Int = 0) -> String {
        switch block {
        case .heading(let level, let text):
            let style = "Heading\(min(max(level, 1), 6))"
            return paragraph(DocxInline.runs(text), style: style, quoteDepth: quoteDepth)

        case .paragraph(let text):
            return paragraph(DocxInline.runs(text), quoteDepth: quoteDepth)

        case .code(_, let code):
            return codeBlock(code, quoteDepth: quoteDepth)

        case .quote(let inner):
            return inner.map { render($0, listDepth: listDepth, quoteDepth: quoteDepth + 1) }.joined()

        case .list(let ordered, _, let items):
            return list(ordered: ordered, items: items, depth: listDepth)

        case .table(let header, let alignments, let rows):
            return table(header: header, alignments: alignments, rows: rows)

        case .divider:
            return dividerXML()

        case .toc:
            return ""
        }
    }

    private func list(ordered: Bool, items: [ListItem], depth: Int) -> String {
        let numID = ordered ? Self.orderedNumberingID : Self.bulletNumberingID
        var xml = ""
        for item in items {
            var numbered = false
            for block in item.blocks {
                switch block {
                case .paragraph(let text):
                    var runs = DocxInline.runs(text)
                    if let state = item.taskState, !numbered {
                        runs.insert(DocxRun.text(state == .checked ? "☑ " : "☐ "), at: 0)
                    }
                    xml += paragraph(
                        runs,
                        style: "ListParagraph",
                        numbering: numbered ? nil : (numID, depth),
                        indent: numbered ? (depth + 1) * 420 : nil
                    )
                    numbered = true

                case .list(let nestedOrdered, _, let nestedItems):
                    xml += list(ordered: nestedOrdered, items: nestedItems, depth: depth + 1)

                default:
                    xml += render(block, listDepth: depth + 1)
                }
            }
            // 空列表项也要占一个编号位，否则编号会跳
            if !numbered {
                xml += paragraph([], style: "ListParagraph", numbering: (numID, depth))
            }
        }
        return xml
    }

    private func codeBlock(_ code: String, quoteDepth: Int) -> String {
        var runs = ""
        for (index, line) in code.components(separatedBy: "\n").enumerated() {
            if index > 0 {
                runs += "<w:r><w:br/></w:r>"
            }
            if !line.isEmpty {
                runs += "<w:r><w:t xml:space=\"preserve\">\(escape(line))</w:t></w:r>"
            }
        }
        var props = "<w:pStyle w:val=\"CodeBlock\"/>"
        if quoteDepth > 0 {
            props += "<w:ind w:left=\"\(360 * quoteDepth)\"/>"
        }
        return "<w:p><w:pPr>\(props)</w:pPr>\(runs)</w:p>"
    }

    private func dividerXML() -> String {
        """
        <w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="D9D9D9"/></w:pBdr>\
        <w:spacing w:before="180" w:after="180"/></w:pPr></w:p>
        """
    }

    // MARK: - 表格

    private func table(header: [String], alignments: [TableAlignment], rows: [[String]]) -> String {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        let width = Self.textWidth / columns

        var xml = """
        <w:tbl><w:tblPr><w:tblW w:type="dxa" w:w="\(Self.textWidth)"/>\
        <w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="D9D9D9"/>\
        <w:left w:val="single" w:sz="4" w:space="0" w:color="D9D9D9"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="D9D9D9"/>\
        <w:right w:val="single" w:sz="4" w:space="0" w:color="D9D9D9"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="D9D9D9"/>\
        <w:insideV w:val="single" w:sz="4" w:space="0" w:color="D9D9D9"/>\
        </w:tblBorders><w:tblLayout w:type="fixed"/></w:tblPr><w:tblGrid>
        """
        xml += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns)
        xml += "</w:tblGrid>"

        var headerRow = "<w:tr><w:trPr><w:tblHeader/></w:trPr>"
        for index in 0..<columns {
            headerRow += cell(
                index < header.count ? header[index] : "",
                width: width,
                alignment: alignment(alignments, index),
                shaded: true
            )
        }
        xml += headerRow + "</w:tr>"

        for row in rows {
            xml += "<w:tr>"
            for index in 0..<columns {
                xml += cell(
                    index < row.count ? row[index] : "",
                    width: width,
                    alignment: alignment(alignments, index),
                    shaded: false
                )
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl>"
    }

    private func alignment(_ alignments: [TableAlignment], _ index: Int) -> TableAlignment {
        index < alignments.count ? alignments[index] : .none
    }

    private func cell(_ text: String, width: Int, alignment: TableAlignment, shaded: Bool) -> String {
        var props = "<w:tcW w:type=\"dxa\" w:w=\"\(width)\"/>"
        if shaded {
            props += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>"
        }
        let runs = DocxInline.runs(text)
        var paragraphProps = ""
        switch alignment {
        case .center: paragraphProps += "<w:jc w:val=\"center\"/>"
        case .right: paragraphProps += "<w:jc w:val=\"right\"/>"
        case .left, .none: break
        }
        let pPr = paragraphProps.isEmpty ? "" : "<w:pPr>\(paragraphProps)</w:pPr>"
        let body = runs.map(runXML).joined()
        // 单元格必须至少有一个 w:p
        let paragraph = body.isEmpty ? "<w:p>\(pPr)</w:p>" : "<w:p>\(pPr)\(body)</w:p>"
        return "<w:tc><w:tcPr>\(props)</w:tcPr>\(paragraph)</w:tc>"
    }

    // MARK: - 段落与 run

    private func paragraph(
        _ runs: [DocxRun],
        style: String? = nil,
        numbering: (numID: Int, level: Int)? = nil,
        alignment: TableAlignment = .none,
        indent: Int? = nil,
        quoteDepth: Int = 0
    ) -> String {
        var props = ""
        if let style {
            props += "<w:pStyle w:val=\"\(style)\"/>"
        }
        if quoteDepth > 0 {
            props += "<w:ind w:left=\"\(360 * quoteDepth)\"/>"
        } else if let indent {
            props += "<w:ind w:left=\"\(indent)\"/>"
        }
        if let numbering {
            props += "<w:numPr><w:ilvl w:val=\"\(min(numbering.level, 8))\"/>"
                + "<w:numId w:val=\"\(numbering.numID)\"/></w:numPr>"
        }
        switch alignment {
        case .center: props += "<w:jc w:val=\"center\"/>"
        case .right: props += "<w:jc w:val=\"right\"/>"
        case .left, .none: break
        }
        let pPr = props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>"
        let body = runs.map(runXML).joined()
        if pPr.isEmpty && body.isEmpty { return "<w:p/>" }
        return "<w:p>\(pPr)\(body)</w:p>"
    }

    private func runXML(_ run: DocxRun) -> String {
        switch run.content {
        case .image(let src, let alt):
            return imageRunXML(src: src, alt: alt)

        case .text(let text):
            guard !text.isEmpty else { return "" }
            var props = ""
            if let link = run.link, !link.isEmpty {
                props += "<w:rStyle w:val=\"Hyperlink\"/>"
            } else if run.code {
                props += "<w:rStyle w:val=\"CodeChar\"/>"
            }
            if run.bold { props += "<w:b/>" }
            if run.italic { props += "<w:i/>" }
            if run.strike { props += "<w:strike/>" }
            let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
            let inner = "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r>"
            if let link = run.link, let id = hyperlinkRelationship(link) {
                return "<w:hyperlink r:id=\"\(id)\">\(inner)</w:hyperlink>"
            }
            return inner
        }
    }

    // MARK: - 图片

    private func imageRunXML(src: String, alt: String) -> String {
        guard let embedded = embedImage(src: src) else {
            // 文件找不到就写回 alt，别让读者以为图被吞了
            guard !alt.isEmpty else { return "" }
            return "<w:r><w:t xml:space=\"preserve\">[\(escape(alt))]</w:t></w:r>"
        }
        let description = escape(alt.isEmpty ? "image" : alt)
        let cx = Int(embedded.size.width * Self.emuPerPoint)
        let cy = Int(embedded.size.height * Self.emuPerPoint)
        var xml = "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\">"
        xml += "<wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
        xml += "<wp:docPr id=\"\(nextDocPrID)\" name=\"image\" descr=\"\(description)\"/>"
        nextDocPrID += 1
        xml += "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\">"
        xml += "<pic:pic><pic:nvPicPr><pic:cNvPr id=\"0\" name=\"image\"/>"
        xml += "<pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(embedded.id)\"/>"
        xml += "<a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
        xml += "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
        xml += "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>"
        xml += "</a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"
        return xml
    }

    private func embedImage(src: String) -> (id: String, size: CGSize)? {
        guard let url = resolveImageURL(src) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = fitted(image.size)

        if let existing = imageIDs[url.path] {
            return (existing, size)
        }

        let raw = try? Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        let (data, fileExtension, contentTypeExtension): (Data, String, String)
        if let raw, ext == "png" {
            (data, fileExtension, contentTypeExtension) = (raw, "png", "png")
        } else if let raw, ext == "jpg" || ext == "jpeg" {
            (data, fileExtension, contentTypeExtension) = (raw, "jpeg", "jpeg")
        } else {
            // 其它格式（gif/tiff/heic…）统一转 PNG：Word 对 PNG 最宽容
            guard let rep = NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
                  let png = rep.representation(using: .png, properties: [:])
            else { return nil }
            (data, fileExtension, contentTypeExtension) = (png, "png", "png")
        }
        _ = contentTypeExtension

        let index = imageIDs.count + 1
        let name = "image\(index).\(fileExtension)"
        let id = addRelationship(type: imageType, target: "media/\(name)", external: false)
        imageIDs[url.path] = id
        media.append((path: "word/media/\(name)", data: data))
        return (id, size)
    }

    private func fitted(_ size: CGSize) -> CGSize {
        guard size.width > Self.textWidthPoints, size.width > 0 else { return size }
        let scale = Self.textWidthPoints / size.width
        return CGSize(width: Self.textWidthPoints, height: (size.height * scale).rounded())
    }

    private func resolveImageURL(_ src: String) -> URL? {
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return nil }
        let decoded = src.removingPercentEncoding ?? src
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded)
        }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: decoded, relativeTo: baseURL)
    }

    // MARK: - 关系

    private func addRelationship(type: String, target: String, external: Bool) -> String {
        let id = "rId\(nextRelID)"
        nextRelID += 1
        relationships.append((id: id, type: type, target: target, external: external))
        return id
    }

    private func hyperlinkRelationship(_ url: String) -> String? {
        guard !url.isEmpty, !url.hasPrefix("#") else { return nil }
        if let existing = hyperlinks[url] { return existing }
        let id = addRelationship(type: hyperlinkType, target: url, external: true)
        hyperlinks[url] = id
        return id
    }

    // MARK: - 部件

    private func contentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Default Extension="jpeg" ContentType="image/jpeg"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
    }

    private func packageRelationshipsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private func documentRelationshipsXML() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        for item in relationships {
            let mode = item.external ? " TargetMode=\"External\"" : ""
            xml += "<Relationship Id=\"\(item.id)\" Type=\"\(item.type)\" Target=\"\(escape(item.target))\"\(mode)/>\n"
        }
        xml += "</Relationships>"
        return xml
    }

    private func corePropertiesXML() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let now = formatter.string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(escape(title))</dc:title>
        <dc:creator>wtmd</dc:creator>
        <cp:lastModifiedBy>wtmd</cp:lastModifiedBy>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private func appPropertiesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
        <Application>wtmd</Application>
        </Properties>
        """
    }

    private func documentXML(body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" \
        w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
    }

    // MARK: - 样式与编号

    private static let bulletNumberingID = 1
    private static let orderedNumberingID = 2

    private func stylesXML() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:docDefaults>\
        <w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica Neue" w:hAnsi="Helvetica Neue" w:eastAsia="PingFang SC"/>\
        <w:sz w:val="22"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
        </w:docDefaults>
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
        """
        let headings: [(Int, Int)] = [(1, 36), (2, 30), (3, 26), (4, 24), (5, 22), (6, 22)]
        for (level, size) in headings {
            xml += """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/>\
            <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:spacing w:before="\(320 - level * 20)" w:after="120"/>\
            <w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
            <w:rPr><w:b/><w:sz w:val="\(size)"/></w:rPr></w:style>
            """
        }
        xml += """
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/>\
        <w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="DDDDDD"/></w:pBdr></w:pPr>\
        <w:rPr><w:color w:val="555555"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="CodeBlock"><w:name w:val="Code Block"/>\
        <w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/>\
        <w:spacing w:before="120" w:after="120" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/><w:sz w:val="18"/></w:rPr></w:style>
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/>\
        <w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="60"/></w:pPr></w:style>
        <w:style w:type="character" w:styleId="CodeChar"><w:name w:val="Code Char"/>\
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo"/>\
        <w:shd w:val="clear" w:color="auto" w:fill="F0F0F0"/><w:sz w:val="20"/></w:rPr></w:style>
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>\
        <w:rPr><w:color w:val="1155CC"/><w:u w:val="single"/></w:rPr></w:style>
        </w:styles>
        """
        return xml
    }

    private func numberingXML() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>
        """
        for level in 0..<9 {
            xml += """
            <w:lvl w:ilvl="\(level)"><w:start w:val="1"/><w:numFmt w:val="bullet"/>\
            <w:lvlText w:val="•"/><w:lvlJc w:val="left"/>\
            <w:pPr><w:ind w:left="\(720 * (level + 1))" w:hanging="360"/></w:pPr>\
            <w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica"/></w:rPr></w:lvl>
            """
        }
        xml += """
        </w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>
        """
        for level in 0..<9 {
            xml += """
            <w:lvl w:ilvl="\(level)"><w:start w:val="1"/><w:numFmt w:val="decimal"/>\
            <w:lvlText w:val="%\(level + 1)."/><w:lvlJc w:val="left"/>\
            <w:pPr><w:ind w:left="\(720 * (level + 1))" w:hanging="360"/></w:pPr></w:lvl>
            """
        }
        xml += """
        </w:abstractNum>
        <w:num w:numId="\(Self.bulletNumberingID)"><w:abstractNumId w:val="0"/></w:num>
        <w:num w:numId="\(Self.orderedNumberingID)"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        return xml
    }

    // MARK: - 转义

    private func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }
}
