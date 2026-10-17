import SwiftUI

/// 文档内查找条。
///
/// 自绘而不是用系统的 find bar：要正则、要 `$1` 反向引用、要和专注模式的压暗
/// 共存，而系统的那条只做字面量查找，样式也与「思绪 / 成文」的气质割裂。
struct FindBar: View {
    @ObservedObject var find: FindController
    var onReplaceCurrent: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void

    @FocusState private var focus: Field?
    /// 手动展开/收起替换栏。`nil` 表示跟着「这次是 ⌘F 还是 ⌥⌘R 打开的」走。
    @State private var showsReplaceOverride: Bool?

    private enum Field: Hashable { case query, replacement }

    private var showsReplace: Bool { showsReplaceOverride ?? find.focusesReplacement }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            searchRow
            if showsReplace { replaceRow }
        }
        .background(.bar)
        .onAppear { focus = find.focusesReplacement ? .replacement : .query }
        .onChange(of: find.focusToken) { _, _ in
            showsReplaceOverride = nil
            focus = find.focusesReplacement ? .replacement : .query
        }
        .onExitCommand { onClose() }
    }

    // MARK: - 第一行

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("查找", text: $find.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 190)
                .focused($focus, equals: .query)
                .onSubmit { find.next() }
                .onKeyPress(keys: [.return]) { press in
                    // ⇧↩ = 上一处；其余交给 onSubmit 处理
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.previous()
                    return .handled
                }

            Text(find.statusText)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(find.patternError == nil ? Color.secondary : Color.red)
                .frame(minWidth: 58, alignment: .leading)
                .lineLimit(1)

            Button { find.previous() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .help("上一处（⇧↩）")
            Button { find.next() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .help("下一处（↩）")

            optionChip("Aa", on: find.options.contains(.caseSensitive), help: "区分大小写") {
                toggle(.caseSensitive)
            }
            optionChip("全词", on: find.options.contains(.wholeWord), help: "全词匹配") {
                toggle(.wholeWord)
            }
            optionChip(".*", on: find.options.contains(.regex), help: "正则表达式") {
                toggle(.regex)
            }

            Spacer(minLength: 4)

            Button {
                showsReplaceOverride = !showsReplace
                if showsReplace { focus = .replacement }
            } label: {
                Label("替换", systemImage: showsReplace ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11))
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("显示替换栏（⌥⌘R）")

            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("关闭（esc）")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    // MARK: - 第二行

    private var replaceRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("替换为", text: $find.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 190)
                .focused($focus, equals: .replacement)
                .onSubmit { onReplaceCurrent() }

            Button("替换") { onReplaceCurrent() }
                .disabled(!find.hasMatches)
            Button("全部替换") { onReplaceAll() }
                .disabled(!find.hasMatches)

            if find.options.contains(.regex) {
                Text("替换文本支持 $1 反向引用")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }

    // MARK: - 小件

    private func optionChip(
        _ label: String,
        on: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(on ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggle(_ option: FindOptions) {
        find.options.formSymmetricDifference(option)
    }
}
