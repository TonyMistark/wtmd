import SwiftUI

/// 磁盘上的文件被别处改过（或被删了）时，横在正文上方的一条提示。
///
/// 单独成一个视图有两个原因：`ContentView` 已经够长了；更重要的是它**能被单独渲染成
/// 图像**——横幅是要给人看的东西，断言「有这两个按钮」证明不了「看起来像条横幅」。
struct ConflictBanner: View {
    let change: ExternalChange
    let fileName: String
    let resolve: (ExternalChangeResolution) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if change == .deleted {
                Button(t("Keep as Draft", "留作草稿")) { resolve(.keepAsDraft) }
                Button(t("Save As…", "另存为…")) { resolve(.saveAs) }
            } else {
                Button(t("Load Disk Version", "载入磁盘版本")) { resolve(.reloadDisk) }
                Button(t("Keep My Changes", "保留我的修改")) { resolve(.keepLocal) }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var icon: String {
        switch change {
        case .deleted: return "trash"
        case .heldElsewhere: return "rectangle.on.rectangle"
        case .modified: return "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch change {
        case .modified: return t("\(fileName) was changed elsewhere", "「\(fileName)」已在别处被修改")
        case .deleted: return t("\(fileName) has been deleted", "「\(fileName)」已被删除")
        case .heldElsewhere:
            return t("\(fileName) is also open in another window", "「\(fileName)」也在另一扇窗口里开着")
        }
    }

    private var detail: String {
        switch change {
        case .modified: return t("Autosave is paused; the version on disk was not overwritten.", "自动保存已暂停，磁盘上的版本没有被覆盖。")
        case .deleted: return t("Autosave is paused. Save the content as a new file, or keep it as a draft.", "自动保存已暂停。另存为一个新文件，或把内容留作草稿。")
        case .heldElsewhere:
            return t(
                "Autosave is paused and your version was saved to the conflict archive. Close it in one of the windows to write again.",
                "自动保存已暂停，你这一版已存入冲突副本。在其中一扇窗里关掉它，才能继续写回原文件。"
            )
        }
    }
}
