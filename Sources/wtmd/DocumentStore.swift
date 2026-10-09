import Foundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import WTMarkdownKit

enum ViewMode: String, CaseIterable, Identifiable {
    case edit, preview
    var id: String { rawValue }
    /// 中心思想的界面落点：源码是思绪的原貌，预览是思绪的成文。
    var label: String { self == .edit ? "思绪" : "成文" }
}

struct JumpRequest: Equatable {
    let id: String
    let line: Int
    let slug: String
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var text: String
    @Published var fileURL: URL?
    @Published var mode: ViewMode = .edit
    @Published var outline: [OutlineItem] = []
    @Published var previewHTML: String = ""
    @Published var currentSlug: String?
    @Published var cursorLine: Int = 0
    @Published var sidebarVisible = true
    @Published var editorJump: JumpRequest?
    @Published var previewJump: JumpRequest?
    /// 强制预览整体重载的代数（打开新文件时递增，重置滚动位置）。
    @Published var renderGeneration = 0

    let recentFiles = RecentFiles()
    let themeManager = ThemeManager()

    private var savedSnapshot: String = ""
    private var renderTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?

    static let welcomeMarkdown = """
    # 欢迎使用 wtmd

    **Where Thoughts Meet Documents** —— 思绪落下的一刻，成文已然成型。

    ## 快速上手

    - 使用 `⌘/` 在**思绪**（源码）与**成文**（预览）之间切换
    - 左侧大纲随标题自动生成，点击即可跳转
    - `⌘O` 打开文件，`⌘S` 保存 —— 文件永远属于你自己
    - 未命名草稿自动保存，重启不丢

    ## 语法速览

    支持**粗体**、*斜体*、~~删除线~~、`行内代码` 与 [链接](https://example.com)。

    > 写作工具应当隐形，心流高于一切。

    ### 代码块

    ```swift
    let greeting = "Hello, wtmd!"
    print(greeting)
    ```

    ### 任务列表

    - [x] 双模式视图
    - [x] 大纲导航
    - [ ] 自定义主题（v0.2）

    ### 表格

    | 操作 | 快捷键 |
    | --- | :---: |
    | 思绪 ⇄ 成文 | ⌘/ |
    | 打开文件 | ⌘O |
    | 保存 | ⌘S |

    ---

    MIT 开源协议 · 数据本地存储 · 标准纯文本
    """

    init() {
        if let draft = Self.readDraft(), !draft.isEmpty {
            text = draft
        } else {
            text = Self.welcomeMarkdown
            Self.writeDraft(text)
        }
        recomputeNow()
    }

    // MARK: - 状态

    var isDirty: Bool { text != savedSnapshot }
    var displayName: String { fileURL?.lastPathComponent ?? "未命名.md" }
    var windowTitle: String { (isDirty ? "● " : "") + displayName }

    func textDidChange(_ new: String) {
        text = new
        scheduleRender()
        scheduleDraftSave()
    }

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .preview { recomputeNow() }
    }

    func toggleMode() {
        setMode(mode == .edit ? .preview : .edit)
    }

    /// 编辑模式下当前光标所在章节 slug（用于大纲高亮）。
    var currentOutlineSlug: String? {
        if mode == .preview { return currentSlug }
        return outline.last(where: { $0.line <= cursorLine })?.slug
    }

    func jump(to item: OutlineItem) {
        let request = JumpRequest(id: UUID().uuidString, line: item.line, slug: item.slug)
        if mode == .edit {
            editorJump = request
        } else {
            previewJump = request
        }
        currentSlug = item.slug
    }

    // MARK: - 渲染

    private func recomputeNow() {
        let result = WTMarkdown.render(text)
        outline = result.outline
        previewHTML = result.html
    }

    private func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            self.recomputeNow()
        }
    }

    // MARK: - 文件

    func newDocument() {
        text = ""
        fileURL = nil
        savedSnapshot = ""
        renderGeneration += 1
        recomputeNow()
        mode = .edit
        Self.clearDraft()
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        text = content
        fileURL = url
        savedSnapshot = content
        recentFiles.add(url)
        renderGeneration += 1
        recomputeNow()
    }

    func save() {
        let targetURL: URL
        if let existing = fileURL {
            targetURL = existing
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "未命名.md"
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            targetURL = url
            fileURL = url
        }
        do {
            try text.write(to: targetURL, atomically: true, encoding: .utf8)
            savedSnapshot = text
            recentFiles.add(targetURL)
            Self.clearDraft()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - 导出

    /// 导出 HTML：独立文件，排版骨架 + 主题变量层全部内联。
    func exportHTML() {
        let result = WTMarkdown.render(text)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = displayName.replacingOccurrences(of: "\\.md$", with: "", options: .regularExpression) + ".html"
        panel.allowedContentTypes = [.html]

        // 附件选项：使用当前主题（不勾则导出默认主题）
        let useCurrent = NSButton(checkboxWithTitle: "使用当前主题样式", target: nil, action: nil)
        useCurrent.state = .on
        useCurrent.controlSize = .small
        panel.accessoryView = useCurrent

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let themeCSS = useCurrent.state == .on
            ? themeManager.currentThemeCSS
            : StyleSheet.cssText(light: Theme.defaultLight, dark: Theme.defaultDark)!
        let html = StyleSheet.fullDocument(
            title: fileURL?.deletingPathExtension().lastPathComponent ?? "wtmd",
            body: result.html,
            themeCSS: themeCSS,
            includeScript: false
        )
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportPDF() {
        let result = WTMarkdown.render(text)
        let html = StyleSheet.fullDocument(
            title: fileURL?.deletingPathExtension().lastPathComponent ?? "wtmd",
            body: result.html,
            themeCSS: themeManager.currentThemeCSS,
            includeScript: false
        )
        PrintController.print(html: html, baseURL: fileURL?.deletingLastPathComponent())
    }

    // MARK: - 草稿

    private static var draftURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("wtmd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("draft.md")
    }

    private static func readDraft() -> String? {
        try? String(contentsOf: draftURL, encoding: .utf8)
    }

    private static func writeDraft(_ content: String) {
        try? content.write(to: draftURL, atomically: true, encoding: .utf8)
    }

    private static func clearDraft() {
        try? FileManager.default.removeItem(at: draftURL)
    }

    private func scheduleDraftSave() {
        guard fileURL == nil else { return }
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self, self.fileURL == nil else { return }
            Self.writeDraft(self.text)
        }
    }
}

// MARK: - 最近文件

final class RecentFiles: ObservableObject {
    private static let key = "wtmd.recentFiles"
    @Published var urls: [URL] = []

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        urls = paths.compactMap { URL(string: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func add(_ url: URL) {
        var next = urls.filter { $0 != url }
        next.insert(url, at: 0)
        if next.count > 8 { next = Array(next.prefix(8)) }
        urls = next
        UserDefaults.standard.set(next.map(\.absoluteString), forKey: Self.key)
    }
}

// MARK: - 打印 / 存为 PDF

@MainActor
final class PrintController: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var retained: [Any] = []

    static func print(html: String, baseURL: URL?) {
        let controller = PrintController()
        controller.run(html: html, baseURL: baseURL)
    }

    private func run(html: String, baseURL: URL?) {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 780, height: 1000))
        webView.navigationDelegate = self
        retained = [webView]
        webView.loadHTMLString(html, baseURL: baseURL)

        Task {
            await withCheckedContinuation { c in
                continuation = c
            }
            // 等待排版稳定
            try? await Task.sleep(nanoseconds: 400_000_000)
            let info = NSPrintInfo.shared
            info.topMargin = 36
            info.bottomMargin = 36
            info.leftMargin = 40
            info.rightMargin = 40
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            let operation = webView.printOperation(with: info)
            operation.jobTitle = "wtmd"
            if let window = NSApp.keyWindow {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            }
            retained = []
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            continuation?.resume()
            continuation = nil
        }
    }
}
