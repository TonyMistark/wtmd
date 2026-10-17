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
            Image(systemName: change == .deleted ? "trash" : "exclamationmark.triangle.fill")
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
                Button("留作草稿") { resolve(.keepAsDraft) }
                Button("另存为…") { resolve(.saveAs) }
            } else {
                Button("载入磁盘版本") { resolve(.reloadDisk) }
                Button("保留我的修改") { resolve(.keepLocal) }
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

    private var title: String {
        switch change {
        case .modified: return "「\(fileName)」已在别处被修改"
        case .deleted: return "「\(fileName)」已被删除"
        }
    }

    private var detail: String {
        switch change {
        case .modified: return "自动保存已暂停，磁盘上的版本没有被覆盖。"
        case .deleted: return "自动保存已暂停。另存为一个新文件，或把内容留作草稿。"
        }
    }
}
