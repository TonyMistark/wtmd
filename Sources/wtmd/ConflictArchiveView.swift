import AppKit
import SwiftUI

/// 「冲突副本」清单：冲突没解决时切走留下的本地版本都在这里。
///
/// 它是一张表，不是一场对话——副本已经存好了，这里只提供「取回 / 丢掉 / 去看看」
/// 三个动作，随时可以关掉走人。
struct ConflictArchiveView: View {
    let entries: [ConflictArchiveEntry]
    /// 副本所在的文件夹（测试里是一个临时目录，正式运行时是 `Application Support`）。
    let folder: URL?
    let recover: (ConflictArchiveEntry) -> Void
    let discard: (ConflictArchiveEntry) -> Void
    let reveal: (ConflictArchiveEntry) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if entries.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(entries) { entry in
                            row(entry)
                            Divider().padding(.leading, 34)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            Divider()
            footer
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("Conflict Copies"))
                .font(.headline)
            Text(t("When a file changes elsewhere and you leave with the conflict unresolved, your version is kept here."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var empty: some View {
        Text(t("Nothing waiting to be recovered."))
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ entry: ConflictArchiveEntry) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "doc.text")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.originalName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.subtitle(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(t("Recover")) { recover(entry) }
                .help(t("Opens as an untitled document — decide where to save it yourself"))
            Button {
                reveal(entry)
            } label: {
                Image(systemName: "folder")
            }
            .help(t("Reveal this copy in Finder"))
            Button(t("Discard")) { discard(entry) }
                .help(t("Deletes this copy; this cannot be undone"))
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            Button(t("Open Folder in Finder")) {
                if let folder { NSWorkspace.shared.open(folder) }
            }
            .buttonStyle(.link)
            .font(.caption)
            .disabled(folder == nil)
            Spacer()
            Button(t("Close"), action: close)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private static func subtitle(for entry: ConflictArchiveEntry) -> String {
        let time = timeFormatter.string(from: entry.savedAt)
        guard let path = entry.originalPath else { return time }
        let folder = (path as NSString).deletingLastPathComponent
        return "\(time) · \(folder)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = L10n.isChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return formatter
    }()
}
