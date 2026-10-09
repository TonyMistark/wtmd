import AppKit
import Foundation
import UniformTypeIdentifiers

/// 图片落地管线：粘贴板/拖拽数据 → assets/ 目录文件 → Markdown 引用文本。
struct ImageAssets {
    /// 从粘贴板提取第一张可用图片的数据（PNG 优先，TIFF 转 PNG）。
    static func imagePNGData(from pasteboard: NSPasteboard) -> Data? {
        let types = pasteboard.types ?? []

        // 1. 直接是文件 URL（拖拽文件 / 复制的文件）
        if types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
               .urlReadingFileURLsOnly: true,
           ]) as? [URL] {
            for url in urls where isImageFile(url) {
                if let data = try? Data(contentsOf: url) {
                    return normalizedPNG(data, pathExtension: url.pathExtension)
                }
            }
        }

        // 2. PNG 原生数据（截图等）
        if let data = pasteboard.data(forType: .png) {
            return normalizedPNG(data, pathExtension: "png")
        }

        // 3. TIFF（NSImage 复制走的通道）
        if let tiff = pasteboard.data(forType: .tiff) {
            return normalizedPNG(tiff, pathExtension: "tiff")
        }

        return nil
    }

    /// 拖拽信息中提取图片数据。
    static func imagePNGData(from draggingInfo: NSDraggingInfo) -> Data? {
        let pasteboard = draggingInfo.draggingPasteboard
        return imagePNGData(from: pasteboard)
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// 统一转 PNG（TIFF/JPEG → PNG）；解码失败返回 nil。
    private static func normalizedPNG(_ data: Data, pathExtension: String) -> Data? {
        if pathExtension.lowercased() == "png", let _ = NSImage(data: data) {
            return data // 已是合法 PNG，免二次编码
        }
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return png
    }

    // MARK: - 落地

    /// 生成不冲突的文件名：截图-YYYYMMDD-HHmmss(-序号).png
    static func makeFileName(in directory: URL, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "zh_CN")
        let stamp = formatter.string(from: date)
        var name = "截图-\(stamp).png"
        var n = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) {
            name = "截图-\(stamp)-\(n).png"
            n += 1
        }
        return name
    }

    /// 将图片数据写入 `<文档目录>/assets/`，返回相对引用路径 `assets/xxx.png`。
    /// - Parameter documentURL: 当前文档 URL（决定 assets 放哪）
    /// - Returns: (相对路径, 绝对 URL)；用户取消或写入失败返回 nil
    @MainActor
    static func save(
        pngData: Data,
        documentURL: URL?
    ) -> (relativePath: String, fileURL: URL)? {
        let baseDir: URL

        if let documentURL {
            baseDir = documentURL.deletingLastPathComponent()
        } else {
            // 未保存的草稿：让用户选一个落地目录
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.message = "选择图片存放目录（将创建 assets 子目录）"
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            baseDir = url
        }

        let assetsDir = baseDir.appendingPathComponent("assets", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            let name = makeFileName(in: assetsDir)
            let fileURL = assetsDir.appendingPathComponent(name)
            try pngData.write(to: fileURL)
            return ("assets/\(name)", fileURL)
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }
}
