import AppKit
import Foundation
import Testing
@testable import wtmd

// MARK: - 文件名生成

@Test func makeFileNameFormat() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-imgtests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let date = Date(timeIntervalSince1970: 1_760_000_000) // 固定时间
    let name = ImageAssets.makeFileName(in: dir, date: date)
    // 格式：截图-YYYYMMDD-HHmmss.png
    #expect(name.hasPrefix("截图-"))
    #expect(name.hasSuffix(".png"))
    #expect(!name.contains("-2.png")) // 目录空，无序号

    // 已存在同名文件 → 带序号
    try! Data([0x89, 0x50]).write(to: dir.appendingPathComponent(name))
    let second = ImageAssets.makeFileName(in: dir, date: date)
    #expect(second == name.replacingOccurrences(of: ".png", with: "-2.png"))
}

// MARK: - 粘贴板图片提取

@Test func pasteboardPNGExtraction() {
    let pb = NSPasteboard.general
    let saved = pb.prepareForNewContents()

    // 无图片内容 → nil
    pb.setString("纯文本", forType: .string)
    #expect(ImageAssets.imagePNGData(from: pb) == nil)

    // 1x1 红点 PNG 数据 → 提取成功
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.lockFocus()
    NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 1, height: 1))
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!

    pb.setData(png, forType: .png)
    let extracted = ImageAssets.imagePNGData(from: pb)
    #expect(extracted != nil)
    #expect(extracted!.count > 8)

    // TIFF 通道 → 转 PNG
    pb.setData(tiff, forType: .tiff)
    let fromTIFF = ImageAssets.imagePNGData(from: pb)
    #expect(fromTIFF != nil)
    #expect(fromTIFF!.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47])) // PNG 魔数

    _ = saved
}

// MARK: - 落地写入（带文档目录）

@Test @MainActor func saveIntoDocumentAssets() throws {
    let docDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmd-imgtests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: docDir) }

    let docURL = docDir.appendingPathComponent("文章.md")
    try "# 标题".write(to: docURL, atomically: true, encoding: .utf8)

    // 1x1 PNG
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.blue.drawSwatch(in: NSRect(x: 0, y: 0, width: 2, height: 2))
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    let png = rep.representation(using: .png, properties: [:])!

    let result = ImageAssets.save(pngData: png, documentURL: docURL)
    #expect(result != nil)

    let relative = result!.relativePath
    #expect(relative.hasPrefix("assets/截图-"))
    #expect(relative.hasSuffix(".png"))

    // 文件真实存在且为 PNG
    let fileURL = result!.fileURL
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    let written = try Data(contentsOf: fileURL)
    #expect(written.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

    // 目录结构正确：<文档目录>/assets/
    #expect(fileURL.deletingLastPathComponent().lastPathComponent == "assets")
    #expect(fileURL.deletingLastPathComponent().deletingLastPathComponent() == docDir)
}
