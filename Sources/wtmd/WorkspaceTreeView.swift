import AppKit
import SwiftUI

// MARK: - 文件树

/// 工作区文件树：点击打开、右键新建 / 改名 / 废纸篓、行内重命名。
///
/// 从 `ContentView` 拆出来有两个原因：树自己的状态（正在改哪一行）不该占着
/// 根视图；它也要能单独渲染成图，供人眼复核排版。
struct WorkspaceTreeView: View {
    @EnvironmentObject var store: DocumentStore
    @EnvironmentObject var workspace: WorkspaceStore

    /// 正在就地改名的那一行（文件或文件夹）。
    @State private var renaming: URL?
    @State private var renameDraft = ""
    /// 改名被拒的原因，显示在输入框下面——一次错误的改名不值得开一场模态对话。
    @State private var renameError: String?
    @FocusState private var renameFocused: Bool

    /// 「新建」刚刚落地的那一行：界面收到后立刻把它变成输入框。
    var body: some View {
        workspaceSection
            .onChange(of: workspace.pendingRename) { _, newValue in
                guard let newValue else { return }
                beginRename(newValue, isDirectory: WorkspaceScanner.isDirectory(newValue))
                workspace.pendingRename = nil
            }
    }

    // MARK: - 工作区

    @ViewBuilder
    private var workspaceSection: some View {
        Section {
            let nodes = workspace.tree?.children ?? []
            if nodes.isEmpty {
                Text("这个文件夹是空的 —— ⌘N 新建一篇，或右键新建文件夹")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(nodes) { node in
                    treeRow(node)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(workspace.rootName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button {
                    workspace.close()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("关闭工作区")
            }
            .contextMenu {
                Button("新建文稿") { createDocument(in: nil) }
                Button("新建文件夹") { createFolder(in: nil) }
                Divider()
                if let root = workspace.root {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    Button("拷贝路径") { copyPath(root) }
                }
            }
        }
    }

    /// 文件树的一行：文件夹可折叠，文件点击即打开，当前文档高亮。
    ///
    /// `AnyView` 是必需的：递归视图的返回类型没法用 `some View` 自引用
    /// （编译器会报 `OpaqueTypeInference`）。
    private func treeRow(_ node: WorkspaceNode) -> AnyView {
        if node.isDirectory {
            return AnyView(
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { workspace.isExpanded(node.url) },
                        set: { workspace.setExpanded(node.url, to: $0) }
                    )
                ) {
                    ForEach(node.children) { child in
                        treeRow(child)
                    }
                } label: {
                    if renaming == node.url {
                        renameField(for: node)
                    } else {
                        Label(node.name, systemImage: "folder")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .contentShape(Rectangle())
                    }
                }
                .contextMenu { contextMenu(for: node) }
            )
        }

        return AnyView(
            Group {
                if renaming == node.url {
                    renameField(for: node)
                } else {
                    Button {
                        store.open(url: node.url)
                    } label: {
                        Label(node.name, systemImage: "doc.text")
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        workspace.selection == node.url ? Color.accentColor : Color.primary
                    )
                }
            }
            .contextMenu { contextMenu(for: node) }
        )
    }

    /// 右键菜单：树行上能做的所有事。
    ///
    /// 删除**进废纸篓**而不是直接 unlink；改名走行内输入框，不弹对话框。
    @ViewBuilder
    private func contextMenu(for node: WorkspaceNode) -> some View {
        if node.isDirectory {
            Button("新建文稿") { createDocument(in: node.url) }
            Button("新建文件夹") { createFolder(in: node.url) }
            Divider()
        } else {
            Button("打开") { store.open(url: node.url) }
            Divider()
        }
        Button("重命名…") { beginRename(node.url, isDirectory: node.isDirectory) }
        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Button("拷贝路径") { copyPath(node.url) }
        Divider()
        Button("移到废纸篓") { trash(node) }
    }

    /// 就地改名：`↩` 提交、`esc` 取消、点到别处也算提交（Finder 的习惯）。
    private func renameField(for node: WorkspaceNode) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("", text: $renameDraft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($renameFocused)
                .onSubmit { commitRename(node) }
                .onExitCommand { cancelRename() }
                .onChange(of: renameFocused) { _, focused in
                    if !focused, renaming == node.url { commitRename(node) }
                }
            if let renameError {
                Text(renameError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private func beginRename(_ url: URL, isDirectory: Bool) {
        renaming = url
        renameDraft = isDirectory
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        renameError = nil
        // 这一行可能是刚插进 List 的：等这一帧画完再抢焦点
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename(_ node: WorkspaceNode) {
        guard renaming == node.url else { return }
        if let error = workspace.rename(node.url, to: renameDraft) {
            renameError = error.errorDescription
            // 失焦提交失败：留在编辑态并把焦点拉回来，别让红字挂在一行不可编辑的文字下
            if !renameFocused { DispatchQueue.main.async { renameFocused = true } }
            return
        }
        renaming = nil
        renameError = nil
    }

    private func cancelRename() {
        renaming = nil
        renameError = nil
    }

    private func createDocument(in directory: URL?) {
        guard let url = workspace.createDocument(in: directory) else { return }
        store.open(url: url)
    }

    private func createFolder(in directory: URL?) {
        workspace.createFolder(in: directory)
    }

    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func trash(_ node: WorkspaceNode) {
        guard let error = workspace.trash(node.url) else { return }
        let alert = NSAlert()
        alert.messageText = "删不掉「\(node.name)」"
        alert.informativeText = error.errorDescription ?? "文件可能正被其他程序占用"
        alert.alertStyle = .warning
        alert.runModal()
    }}
