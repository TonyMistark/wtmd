import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// 拖拽正悬在哪一行上（文件夹行或工作区根），用来染那一层强调色。
    @State private var dropTarget: URL?
    /// 移不动的原因：就地一行红字，几秒后自消，不弹模态。
    @State private var dropError: String?

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
        // 收放不在这里做：整个组（含文件夹标题行）是否显示，由侧栏
        // 「工作区」分类头的展开开关决定（ContentView 的 Section(isExpanded:)）。
        // 这里只管树本身；标题行双击仍是个开关，跟分类头拨的是同一个状态。
        Section {
            if let dropError {
                Text(dropError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            let nodes = workspace.tree?.children ?? []
            if nodes.isEmpty {
                Text(t("This folder is empty — press ⌘N for a new document, or right-click for a new folder"))
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
                    .dropHighlight(dropTarget == workspace.root)
                    .onDrop(
                        of: [WorkspaceDrag.type],
                        isTargeted: dropBinding(for: workspace.root)
                    ) { providers in
                        acceptDrop(providers, into: workspace.root)
                    }
                Spacer(minLength: 4)
            }
            // 整行都是开关：双击收起 / 放出整个工作区组——收起后这行标题
            // 也一起让位，大纲顶到侧栏最上面。收放不该跟「删掉工作区」
            // 共用一颗按钮。
            .contentShape(Rectangle())
            .pressFeedback()
            .onTapGesture(count: 2) { workspace.sectionExpanded.toggle() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(t("Double-click to collapse or expand the workspace section"))
            .contextMenu {
                Button(t("New Document")) { createDocument(in: nil) }
                Button(t("New Folder")) { createFolder(in: nil) }
                Divider()
                if let root = workspace.root {
                    Button(t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    Button(t("Copy Path")) { copyPath(root) }
                }
                Divider()
                // 解除工作区只是断开 wtmd 与文件夹的访问关系，不碰磁盘——
                // 但整棵树当场消失，看上去足够像「删库」，值得一道确认。
                Button(t("Detach Workspace…"), role: .destructive) { confirmDetachWorkspace() }
            }
        }
    }

    /// 解除工作区的二次确认：弹窗把「文件不会有任何改动」说清楚。
    private func confirmDetachWorkspace() {
        let alert = NSAlert()
        alert.messageText = t("Unbind this workspace?")
        alert.informativeText = t("Only the connection between wtmd and this folder is removed. The folder and its files will not be touched.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: t("Detach"))
        alert.addButton(withTitle: t("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            workspace.close()
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
                            .pressFeedback()
                            // 双击整行也切换展开/收起——箭头只有几像素宽，
                            // 整行都该是开关（与工作区标题行同一习惯）。
                            .onTapGesture(count: 2) {
                                workspace.setExpanded(node.url, to: !workspace.isExpanded(node.url))
                            }
                            .dropHighlight(dropTarget == node.url)
                            .onDrag { WorkspaceDrag.provider(for: node.url) }
                            .onDrop(
                                of: [WorkspaceDrag.type],
                                isTargeted: dropBinding(for: node.url)
                            ) { providers in
                                acceptDrop(providers, into: node.url)
                            }
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
                    // 不用 Button：macOS 上按钮会吃掉拖拽手势，那样这一行就永远
                    // 抓不起来。点击改用 tap，拖拽才拿得到鼠标。
                    Label(node.name, systemImage: "doc.text")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .pressFeedback()
                        .foregroundStyle(
                            workspace.selection == node.url ? Color.accentColor : Color.primary
                        )
                        .onTapGesture { store.open(url: node.url) }
                        .accessibilityAddTraits(.isButton)
                        .onDrag { WorkspaceDrag.provider(for: node.url) }
                }
            }
            .contextMenu { contextMenu(for: node) }
        )
    }

    /// 右键菜单：树行上能做的所有事。
    ///
    /// **没有删除**——写作工具不该在右键里放一把对真实文件生效的刀；
    /// 删文件请走访达，那里有废纸篓和它自己的习惯。改名走行内输入框，不弹对话框。
    @ViewBuilder
    private func contextMenu(for node: WorkspaceNode) -> some View {
        if node.isDirectory {
            Button(t("New Document")) { createDocument(in: node.url) }
            Button(t("New Folder")) { createFolder(in: node.url) }
            Divider()
        } else {
            Button(t("Open")) { store.open(url: node.url) }
            Divider()
        }
        Button(t("Rename…")) { beginRename(node.url, isDirectory: node.isDirectory) }
        Button(t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
        Button(t("Copy Path")) { copyPath(node.url) }
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

    // MARK: - 拖拽移动

    /// 一行的悬停状态。`isTargeted` 每次进出都会回调，只有当前悬停写在状态里，
    /// 免得两行同时亮着。
    private func dropBinding(for url: URL?) -> Binding<Bool> {
        Binding(
            get: { url != nil && dropTarget == url },
            set: { targeted in
                if targeted {
                    dropTarget = url
                } else if dropTarget == url {
                    dropTarget = nil
                }
            }
        )
    }

    /// 只接树里抓起来的那一行：载荷是我们自己的 UTI，访达拖进来的文件不认。
    private func acceptDrop(_ providers: [NSItemProvider], into directory: URL?) -> Bool {
        guard let directory,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(WorkspaceDrag.type.identifier)
              })
        else { return false }

        provider.loadItem(
            forTypeIdentifier: WorkspaceDrag.type.identifier,
            options: nil
        ) { item, _ in
            guard let data = Self.payload(from: item),
                  let source = WorkspaceDrag.url(fromPayload: data)
            else { return }
            DispatchQueue.main.async {
                performMove(source, into: directory)
            }
        }
        return true
    }

    /// `loadItem` 回来的可能是 `Data` 也可能是 `NSData`，两种都认。
    private static func payload(from item: NSSecureCoding?) -> Data? {
        if let data = item as? Data { return data }
        if let data = item as? NSData { return data as Data }
        return nil
    }

    private func performMove(_ source: URL, into directory: URL) {
        dropTarget = nil
        guard let error = workspace.move(source, into: directory) else { return }
        showDropError(error.errorDescription ?? t("Could not move {}", source.lastPathComponent))
    }

    private func showDropError(_ message: String) {
        dropError = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if dropError == message { dropError = nil }
        }
    }

    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}

/// 拖拽悬停时的底色：改变的是这一行读起来的样子，而不是它的排布——
/// 加边框会让整棵树在拖拽时抖一下。
private struct DropHighlight: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(isActive ? 0.18 : 0))
        )
    }
}

private extension View {
    func dropHighlight(_ isActive: Bool) -> some View {
        modifier(DropHighlight(isActive: isActive))
    }
}
