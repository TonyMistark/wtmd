import Foundation
import Testing
@testable import wtmd

// MARK: - 去 GitHub 的路

/// 只拼链接，不代读者提交。这里守两件事：**该编码的都编码了**（中文、
/// 换行、`&`），**整条不许超长**（浏览器和 GitHub 都有上限，按字符数算会翻车）。

private func queryValue(_ url: URL, _ name: String) -> String? {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == name }?.value
}

@Test("标题与正文都进了链接，中文按 UTF-8 编码")
func titleAndBodyAreCarried() throws {
    let url = try #require(GitHubIssue.newIssueURL(
        title: "[崩溃] SIGSEGV · v0.13.0",
        body: "# 报告\n\n- 版本：0.13.0\n- 窗口：3 扇"
    ))

    #expect(url.host == "github.com")
    #expect(url.path == "/TonyMistark/wtmd/issues/new")
    #expect(queryValue(url, "title") == "[崩溃] SIGSEGV · v0.13.0")
    let body = try #require(queryValue(url, "body"))
    #expect(body.contains("版本：0.13.0"))
    #expect(body.contains("窗口：3 扇"))
    // 换行必须编码，否则链接在第一个换行处就断了
    #expect(!url.absoluteString.contains("\n"))
    #expect(url.absoluteString.contains("%0A"))
}

@Test("超长正文按编码后的长度截断——一个汉字九字节")
func longBodyIsTruncated() throws {
    // 三千个汉字：编码后约 27KB，远超上限
    let body = String(repeating: "崩溃现场很长很长。", count: 300)
    let url = try #require(GitHubIssue.newIssueURL(title: "标题", body: body))

    #expect(url.absoluteString.count <= GitHubIssue.lengthLimit)
    // 截断要留话：读者得知道完整内容还在应用里
    let decoded = try #require(queryValue(url, "body"))
    #expect(decoded.contains("截断"))
}

@Test("短正文一个字节都不动")
func shortBodyIsUntouched() throws {
    let body = "# 报告\n\n一切都好。"
    let url = try #require(GitHubIssue.newIssueURL(title: "标题", body: body))
    #expect(queryValue(url, "body") == body)
}

@Test("标题过长时截断，不把整条链接撑爆")
func longTitleIsClipped() {
    let clipped = GitHubIssue.clipped(String(repeating: "标题", count: 200), to: 140)
    #expect(clipped.count <= 141)
    #expect(clipped.hasSuffix("…"))
}
