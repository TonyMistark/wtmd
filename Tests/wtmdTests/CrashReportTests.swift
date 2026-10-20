import Foundation
import Testing
@testable import wtmd

// MARK: - 现场原文

/// 信号处理器写下的那几个字段。这里守的是**解析**：写的那一头在强杀进程的
/// 路径上，测试替它造出同样形状的文件。

private let signalRaw = """
WTMDCRASH 1
base 0x104000000
kind signal
signal SIGSEGV
frames
0   wtmd    0x0000000104a1b2c3 EditorTextView.draw(_:) + 42
1   wtmd    0x0000000104a1c001 DocumentStore.textDidChange(_:) + 118
2   AppKit  0x00000001a2b3c4d5 -[NSView display] + 99
end

"""

@Test("原始文件：信号名与栈都读得出来")
func rawSignalIsParsed() {
    let raw = CrashRaw.parse(signalRaw)
    #expect(raw.kind == .signal)
    #expect(raw.signal == "SIGSEGV")
    #expect(raw.frames.count == 3)
    #expect(raw.frames.first?.contains("EditorTextView") == true)
}

@Test("原始文件：只有头没有栈 = 没抓到现场")
func rawWithoutFramesStaysEmpty() {
    let raw = CrashRaw.parse("WTMDCRASH 1\nbase 0x104000000\n")
    #expect(raw.frames.isEmpty)
    #expect(raw.signal == nil)
}

@Test("原始文件：异常名与原因各占一行")
func rawExceptionIsParsed() {
    let text = """
    kind exception
    exception NSInternalInconsistencyException
    reason Invalid parameter not satisfying: index < count
    frames
    0   wtmd   0x1 main + 1
    end
    """
    let raw = CrashRaw.parse(text)
    #expect(raw.kind == .exception)
    #expect(raw.exceptionName == "NSInternalInconsistencyException")
    #expect(raw.exceptionReason == "Invalid parameter not satisfying: index < count")
    #expect(raw.frames.count == 1)
}

// MARK: - 报告本身

private func sampleReport(
    kind: CrashReport.Kind = .signal,
    signal: String? = "SIGSEGV",
    windows: Int? = 3,
    document: String? = "第二章.md"
) -> CrashReport {
    CrashReport.make(
        capturedAt: Date(timeIntervalSince1970: 1_790_000_000),
        kind: kind,
        signal: signal,
        appVersion: "0.13.0",
        system: "macOS 15.5",
        architecture: "arm64",
        windowCount: windows,
        documentName: document,
        body: "# 报告\n\n正文"
    )
}

@Test("写下去再读回来：字段一个不少")
func reportRoundTrips() throws {
    let original = sampleReport()
    let parsed = try #require(CrashReport.parse(original.markdown))

    #expect(parsed.id == original.id)
    #expect(parsed.kind == .signal)
    #expect(parsed.signal == "SIGSEGV")
    #expect(parsed.appVersion == "0.13.0")
    #expect(parsed.system == "macOS 15.5")
    #expect(parsed.architecture == "arm64")
    #expect(parsed.windowCount == 3)
    #expect(parsed.documentName == "第二章.md")
    // 时间精确到秒：格式化再解析不许漂
    #expect(abs(parsed.capturedAt.timeIntervalSince(original.capturedAt)) < 1)
}

@Test("不是报告的文本读不出来，也不炸")
func plainTextIsNotAReport() {
    #expect(CrashReport.parse("# 一篇普通的稿子\n\n没有元数据。") == nil)
}

@Test("SIGSEGV 有一句人话解释")
func signalsAreExplainedInPlainLanguage() {
    let text = CrashReport.explain(signal: "SIGSEGV")
    #expect(text.contains("内存"))
    // 认不出的信号不许编：只能说「系统把它停掉了」
    #expect(CrashReport.explain(signal: "SIGWEIRD").isEmpty == false)
}

@Test("标题与摘要带上版本、系统与窗口数")
func titleAndSummaryReadLikeASentence() {
    let report = sampleReport()
    #expect(report.suggestedIssueTitle.contains("[崩溃]"))
    #expect(report.suggestedIssueTitle.contains("SIGSEGV"))
    #expect(report.suggestedIssueTitle.contains("0.13.0"))
    #expect(report.summaryLine.contains("0.13.0"))
    #expect(report.summaryLine.contains("macOS 15.5"))
    #expect(report.summaryLine.contains("3 扇窗口"))
}

@Test("没抓到现场的这份不冒充崩溃：标题说「退出」，解释里点名 kill")
func terminatedReportIsNotACrash() {
    let report = sampleReport(kind: .terminated, signal: nil)
    #expect(report.suggestedIssueTitle.contains("[退出]"))
    // 没有栈、没有信号，说成崩溃会让人去查一个不存在的缺陷（#143）
    #expect(!report.suggestedIssueTitle.contains("[崩溃]"))
    #expect(report.explanation.contains("没抓到现场"))
    #expect(report.explanation.contains("kill"))
}

@Test("只开一扇窗时不提窗口数——那是默认情况")
func singleWindowStaysQuiet() {
    #expect(!sampleReport(windows: 1).summaryLine.contains("窗口"))
    #expect(!sampleReport(windows: nil).summaryLine.contains("窗口"))
}

// MARK: - 正文

@Test("崩溃正文：栈与轨迹都在，文档名只有名字没有内容")
func crashBodyCarriesTheTrail() {
    let raw = CrashRaw.parse(signalRaw)
    let breadcrumbs = [
        "15:02:11 launch wtmd 0.13.0",
        "15:02:12 windows 3",
        "15:02:40 doc 第二章.md",
    ]
    let body = CrashReport.crashBody(
        raw: raw, breadcrumbs: breadcrumbs, capturedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    #expect(body.contains("SIGSEGV"))
    #expect(body.contains("EditorTextView"))
    #expect(body.contains("doc 第二章.md"))
    #expect(body.contains("0.13.0"))
    // 轨迹逐行进代码块，读的人能对上「第几秒做了什么」
    #expect(body.contains("15:02:12 windows 3"))
}

@Test("没抓到现场时说清楚，而不是给一个空栈")
func terminatedBodySaysSo() {
    let body = CrashReport.crashBody(
        raw: CrashRaw(), breadcrumbs: [], capturedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
    #expect(body.contains("没抓到现场"))
    // 没有栈就不给一个空的小节标题（结尾那句「只有版本…和调用栈」不算）
    #expect(!body.contains("## 调用栈"))
}

@Test("轨迹里认得出窗口数与文档名")
func breadcrumbsAreInterpreted() {
    let lines = [
        "15:02:11 launch wtmd 0.13.0",
        "15:02:12 windows 2",
        "15:02:40 doc 第一章.md",
        "15:03:01 windows 4",
        "15:03:02 doc 第三章.md",
    ]
    #expect(CrashReport.windowCount(in: lines) == 4)
    #expect(CrashReport.documentName(in: lines) == "第三章.md")
    #expect(CrashReport.windowCount(in: []) == nil)
    #expect(CrashReport.documentName(in: []) == nil)
}

@Test("多行原因压成一行——元数据一行一个字段")
func reasonsFoldToOneLine() {
    #expect(CrashReport.oneLine("第一行\n\n  第二行  ") == "第一行 第二行")
}
