import SwiftUI

// MARK: - 设置 › 快捷键

/// 命令快捷键的改派面板。目录里的出厂值原样列出，用户改派过的条目带一个
/// 「恢复默认」；录入走一个聚焦的小输入框，按下的组合键即生效。
struct ShortcutSettingsView: View {
    @EnvironmentObject var overrides: ShortcutOverrides
    @FocusState private var recorderFocused: Bool

    /// 正在等待按键的那条命令（`CommandKind.id`）。
    @State private var recordingID: String?
    /// 最近一次被拒绝的原因，显示在列表末尾。
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Text(t("Click Record, then press the new combination — it takes effect at once. esc cancels.", "点「录入」后按下新的组合键，立即生效。esc 取消录入。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(groups, id: \.section) { group in
                Section(group.section.title) {
                    ForEach(group.commands) { command in
                        row(command)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(t("Reset All", "全部恢复默认")) {
                        overrides.resetAll()
                        recordingID = nil
                        message = nil
                    }
                    .disabled(overrides.overrides.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 行

    @ViewBuilder
    private func row(_ command: AppCommand) -> some View {
        HStack(spacing: 10) {
            Text(command.title)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRecording(command) {
                recorder
            } else {
                Text(label(for: command))
                    .foregroundStyle(
                        overrides.overrides[command.kind.id] != nil ? Color.accentColor : Color.secondary
                    )
                    .monospaced()
                    .help(overrides.overrides[command.kind.id] != nil ? t("Reassigned — reset to restore the default", "已改派，恢复默认可回到出厂设置") : t("Factory default", "出厂设置"))

                if overrides.overrides[command.kind.id] != nil {
                    Button(t("Reset", "恢复默认")) {
                        _ = overrides.assign(nil, for: command.kind)
                        message = nil
                    }
                }
                Button(t("Record", "录入")) {
                    recordingID = command.kind.id
                    message = nil
                    // 状态先落地，焦点随后跟上；没有焦点时点输入框照样能录
                    DispatchQueue.main.async { recorderFocused = true }
                }
            }
        }
        .controlSize(.small)
    }

    /// 正在录入时的那个小框：按下的键不会写进文本（`onKeyPress` 返回 .handled），
    /// 只被拿去改派。
    private var recorder: some View {
        TextField(t("Press a combination…", "按下组合键…"), text: .constant(""))
            .textFieldStyle(.roundedBorder)
            .frame(width: 150)
            .focused($recorderFocused)
            .onKeyPress { press in
                handle(press)
                return .handled
            }
    }

    // MARK: - 录制

    private func handle(_ press: KeyPress) {
        guard let id = recordingID else { return }
        if press.key == .escape {
            recordingID = nil
            return
        }
        guard let recorded = RecordedShortcut.from(key: press.key.character, modifiers: press.modifiers) else { return }
        guard let kind = CommandKind(ownerID: id) else {
            recordingID = nil
            return
        }
        switch overrides.assign(recorded, for: kind) {
        case .assigned:
            recordingID = nil
            message = nil
        case .rejected(let reason):
            message = reason
        }
    }

    // MARK: - 展示

    private func isRecording(_ command: AppCommand) -> Bool {
        recordingID == command.kind.id
    }

    private func label(for command: AppCommand) -> String {
        guard let shortcut = overrides.effectiveShortcut(for: command.kind) else { return t("None", "无") }
        return RecordedShortcut(shortcut)?.label ?? t("None", "无")
    }

    /// 出厂命令按界面分组列出；主题与最近文件不参与快捷键。
    private var groups: [(section: CommandSection, commands: [AppCommand])] {
        var order: [CommandSection] = []
        var bySection: [CommandSection: [AppCommand]] = [:]
        for command in CommandCatalog.staticCommands {
            if bySection[command.section] == nil { order.append(command.section) }
            bySection[command.section, default: []].append(command)
        }
        return order.map { (section: $0, commands: bySection[$0] ?? []) }
    }
}
