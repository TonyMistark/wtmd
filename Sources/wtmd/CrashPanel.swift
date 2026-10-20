import AppKit
import SwiftUI

/// 崩完之后的那一屏。
///
/// 它要回答三个问题，顺序不能乱：**刚才发生了什么**（一句话说人话）、
/// **东西还在不在**（自动保存与草稿已经写过盘，这份报告也在本机）、
/// **我能做什么**（复制 / 找到文件 / 去 GitHub 说一声）。
///
/// 不做「发送」按钮：没有服务器可发。发不发、发给谁，由读者按下那个链接决定。
struct CrashPanel: View {
    let report: CrashReport?
    /// 还有几份没处理。连着崩的时候先看最新的那份。
    let extraCount: Int
    let copy: (CrashReport) -> Void
    let reveal: (CrashReport) -> Void
    let openIssue: (CrashReport) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let report {
                details(report)
            } else {
                empty
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 头

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: report?.iconName ?? "exclamationmark.triangle.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 5) {
                Text(report?.headline ?? t("wtmd crashed", "wtmd 上次崩溃了"))
                    .font(.title3.weight(.semibold))
                if let report {
                    Text(report.summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(report.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = Self.extraNote(extraCount) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var tint: Color {
        switch report?.kind {
        case .feedback: return .accentColor
        case .terminated: return .secondary
        default: return .orange
        }
    }

    /// 「还有 2 份更早的记录」——不展开，也不假装没有。
    static func extraNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return t(
            "\(count) earlier report(s) are kept in the same folder.",
            "同一个文件夹里还留着 \(count) 份更早的记录。"
        )
    }

    // MARK: 细节

    private func details(_ report: CrashReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(t("What was captured", "抓到的现场"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(t("Read-only", "只读"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ScrollView {
                Text(report.markdown)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 14)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text(t("No crash report on disk.", "磁盘上没有崩溃报告。"))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 底

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(t("Reveal in Finder", "在访达中显示")) {
                    if let report { reveal(report) }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(report == nil)

                Button(t("Copy Report", "复制报告")) {
                    if let report { copy(report) }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(report == nil)

                Spacer()

                Button(t("Ignore", "忽略"), action: dismiss)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)

                Button(t("Report on GitHub…", "在 GitHub 上报告…")) {
                    if let report { openIssue(report) }
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(report == nil)
            }

            Text(t(
                "The report stays on this Mac. The button opens a new GitHub issue with "
                    + "the details filled in — nothing is posted until you press Submit. "
                    + "It never contains text from your documents.",
                "报告只留在这台 Mac 上。那个按钮会打开一个已经填好的新 issue 页面，"
                    + "你按下提交才算发出去。报告里没有任何正文。"
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
