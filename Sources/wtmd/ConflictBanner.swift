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
                Button(t("Keep as Draft")) { resolve(.keepAsDraft) }
                Button(t("Save As…")) { resolve(.saveAs) }
            } else {
                Button(t("Load Disk Version")) { resolve(.reloadDisk) }
                Button(t("Keep My Changes")) { resolve(.keepLocal) }
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
        case .modified: return t("{} was changed elsewhere", fileName)
        case .deleted: return t("{} has been deleted", fileName)
        case .heldElsewhere:
            return t("{} is also open in another window", fileName)
        }
    }

    private var detail: String {
        switch change {
        case .modified: return t("Autosave is paused; the version on disk was not overwritten.")
        case .deleted: return t("Autosave is paused. Save the content as a new file, or keep it as a draft.")
        case .heldElsewhere:
            return t("Autosave is paused and your version was saved to the conflict archive. Close it in one of the windows to write again.")
        }
    }
}
