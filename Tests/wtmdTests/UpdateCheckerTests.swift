import Foundation
import Testing
@testable import wtmd

// MARK: - 版本比较

@Test func versionIgnoresLeadingVAndMissingSegments() throws {
    let short = try #require(AppVersion("0.4"))
    let long = try #require(AppVersion("v0.4.0"))
    #expect(short == long)
    #expect(!(short < long))
    #expect(!(long < short))
}

@Test func versionComparesNumericallyNotLexically() throws {
    let ten = try #require(AppVersion("0.10.0"))
    let nine = try #require(AppVersion("0.9.9"))
    #expect(ten > nine)
    #expect(nine < ten)
}

@Test func prereleaseSortsBeforeSameNumberedRelease() throws {
    let beta = try #require(AppVersion("0.4.0-beta"))
    let final = try #require(AppVersion("0.4.0"))
    #expect(beta < final)
    #expect(final > beta)
}

@Test func prereleaseIdentifiersCompareByNumberAndName() throws {
    let beta1 = try #require(AppVersion("0.4.0-beta.1"))
    let beta2 = try #require(AppVersion("0.4.0-beta.2"))
    let alpha = try #require(AppVersion("0.4.0-alpha"))
    #expect(beta1 < beta2)
    #expect(alpha < beta1)
    // semver：数字标识小于字母标识
    let numeric = try #require(AppVersion("1.0.0-1"))
    let named = try #require(AppVersion("1.0.0-alpha"))
    #expect(numeric < named)
}

@Test func buildMetadataDoesNotAffectOrdering() throws {
    let plain = try #require(AppVersion("0.4.0"))
    let built = try #require(AppVersion("0.4.0+build.7"))
    #expect(plain == built)
}

@Test func malformedVersionsAreRejected() {
    #expect(AppVersion("") == nil)
    #expect(AppVersion("v") == nil)
    #expect(AppVersion("nightly") == nil)
    #expect(AppVersion("1.x.0") == nil)
    #expect(AppVersion("0.4.0-") == nil)
}

// MARK: - 检查流程

/// 测试替身故意不加 `@MainActor`：注入的闭包不是隔离的，替身保持普通类型最简单。
private final class UpdateStub {
    /// 按源名回话：双源检查时 GitHub 与 Gitee 各答各的。
    var calls = 0
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var replies: [String: Result<(Data, URLResponse), Error>] = [:]

    func reply(
        _ source: String = "GitHub", tag: String, draft: Bool = false, prerelease: Bool = false,
        assetName: String? = nil, assetSize: Int? = nil, status: Int = 200
    ) throws {
        var body: [String: Any] = ["tag_name": tag]
        if let url = URL(string: "https://example.invalid/\(source.lowercased())/releases/tag/\(tag)") {
            body["html_url"] = url.absoluteString
        }
        body["draft"] = draft
        body["prerelease"] = prerelease
        if let assetName {
            body["assets"] = [[
                "name": assetName,
                "size": assetSize ?? 0,
                "browser_download_url": "https://example.invalid/\(source.lowercased())/dl/\(assetName)",
            ]]
        }
        try setReply(source, json: body, status: status)
    }

    /// 模拟 Gitee 的 JSON：没有 `html_url`、没有 `draft`/`prerelease` 字段。
    func replyGiteeLike(tag: String, status: Int = 200) throws {
        try setReply("Gitee", json: ["tag_name": tag], status: status)
    }

    private func setReply(_ source: String, json: [String: Any], status: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/latest")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )
        )
        replies[source] = .success((data, response))
    }

    func replyRaw(_ text: String, status: Int = 200) throws {
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/latest")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )
        )
        replies["GitHub"] = .success((Data(text.utf8), response))
    }

    /// 默认全员「连接失败」。
    var defaultFailure: Result<(Data, URLResponse), Error> = .failure(URLError(.notConnectedToInternet))

    func answer(_ source: UpdateChecker.Configuration.Source) throws -> (Data, URLResponse) {
        calls += 1
        return try (replies[source.name] ?? defaultFailure).get()
    }
}

@MainActor
private final class UpdateHarness {
    let suite: String
    let defaults: UserDefaults
    let stub = UpdateStub()
    let currentVersion: String

    init(currentVersion: String = "0.3.0") throws {
        self.currentVersion = currentVersion
        suite = "wtmd.tests.updates.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    func checker(sources: [UpdateChecker.Configuration.Source]? = nil, interval: TimeInterval = 24 * 3600, retryInterval: TimeInterval = 3600) -> UpdateChecker {
        let stub = stub
        return UpdateChecker(
            configuration: UpdateChecker.Configuration(
                currentVersion: currentVersion,
                sources: sources ?? [UpdateChecker.Configuration.Source(
                    name: "GitHub",
                    endpoint: URL(string: "https://example.invalid/latest")!
                )],
                interval: interval,
                retryInterval: retryInterval
            ),
            defaults: defaults,
            now: { stub.now },
            fetch: { source in try stub.answer(source) }
        )
    }

    /// GitHub + Gitee 双源，端点与默认配置同构（测试替身域）。
    func dualChecker() -> UpdateChecker {
        checker(sources: [
            UpdateChecker.Configuration.Source(
                name: "GitHub",
                endpoint: URL(string: "https://example.invalid/github/latest")!,
                pageTemplate: "https://example.invalid/github/releases/tag/{}"
            ),
            UpdateChecker.Configuration.Source(
                name: "Gitee",
                endpoint: URL(string: "https://example.invalid/gitee/latest")!,
                pageTemplate: "https://example.invalid/gitee/releases/tag/{}"
            ),
        ])
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}

@Test @MainActor func newerReleaseIsOffered() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.4.0")

    let checker = harness.checker()
    await checker.check(force: true)

    let expectedURL = try #require(URL(string: "https://example.invalid/github/releases/tag/v0.4.0"))
    #expect(checker.status == .available(version: "0.4.0", sources: [
        UpdateSource(name: "GitHub", asset: nil, releaseURL: expectedURL),
    ]))
    #expect(harness.stub.calls == 1)
}

@Test @MainActor func sameVersionReportsUpToDate() async throws {
    let harness = try UpdateHarness(currentVersion: "0.4.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.4.0")

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .upToDate(version: "0.4.0"))
}

@Test @MainActor func olderReleaseDoesNotOfferDowngrade() async throws {
    let harness = try UpdateHarness(currentVersion: "0.4.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.3.9")

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .upToDate(version: "0.4.0"))
}

/// 预发布版不该被推给普通用户——哪怕它比当前版本高。
@Test @MainActor func prereleaseIsIgnored() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.5.0-beta.1", prerelease: true)

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .upToDate(version: "0.3.0"))
}

@Test @MainActor func draftIsIgnored() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.5.0", draft: true)

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .upToDate(version: "0.3.0"))
}

@Test @MainActor func unparsableTagFallsBackToUpToDate() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "nightly")

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .upToDate(version: "0.3.0"))
}

@Test @MainActor func networkFailureIsSilent() async throws {
    let harness = try UpdateHarness()
    defer { harness.cleanup() }
    // 默认 stub 就是「连接失败」

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .failed)
}

@Test @MainActor func httpErrorIsTreatedAsFailure() async throws {
    let harness = try UpdateHarness()
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.4.0", status: 500)

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .failed)
}

@Test @MainActor func malformedPayloadIsTreatedAsFailure() async throws {
    let harness = try UpdateHarness()
    defer { harness.cleanup() }
    try harness.stub.replyRaw("not json at all")

    let checker = harness.checker()
    await checker.check(force: true)

    #expect(checker.status == .failed)
}

// MARK: - 节流

@Test @MainActor func secondLaunchWithinADaySkipsTheRequest() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.4.0")

    let first = harness.checker()
    await first.checkIfDue()
    #expect(harness.stub.calls == 1)

    // 换一个实例模拟下次启动，时钟只推进一小时
    harness.stub.now = harness.stub.now.addingTimeInterval(3600)
    let second = harness.checker()
    await second.checkIfDue()
    #expect(harness.stub.calls == 1)
}

@Test @MainActor func nextDayChecksAgain() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.4.0")

    await harness.checker().checkIfDue()
    #expect(harness.stub.calls == 1)

    harness.stub.now = harness.stub.now.addingTimeInterval(24 * 3600 + 60)
    await harness.checker().checkIfDue()
    #expect(harness.stub.calls == 2)
}

/// 失败后重试要更早（1 小时），否则离线用户每次启动都撞一次网络超时。
@Test @MainActor func failureRetriesSoonerThanSuccess() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    // 先失败
    await harness.checker().checkIfDue()
    #expect(harness.stub.calls == 1)

    // 半小时后：还在失败静默期，不查
    harness.stub.now = harness.stub.now.addingTimeInterval(30 * 60)
    await harness.checker().checkIfDue()
    #expect(harness.stub.calls == 1)

    // 一小时零一分后：重试
    harness.stub.now = harness.stub.now.addingTimeInterval(31 * 60)
    try harness.stub.reply(tag: "v0.4.0")
    let checker = harness.checker()
    await checker.checkIfDue()
    #expect(harness.stub.calls == 2)
    #expect(checker.status == .available(version: "0.4.0", sources: [
        UpdateSource(name: "GitHub", asset: nil,
                     releaseURL: try #require(URL(string: "https://example.invalid/github/releases/tag/v0.4.0"))),
    ]))
}

@Test @MainActor func manualCheckBypassesThrottle() async throws {
    let harness = try UpdateHarness(currentVersion: "0.3.0")
    defer { harness.cleanup() }
    try harness.stub.reply(tag: "v0.4.0")

    await harness.checker().checkIfDue()
    #expect(harness.stub.calls == 1)

    // 手动「检查更新…」不受 24 小时静默期限制
    await harness.checker().check(force: true)
    #expect(harness.stub.calls == 2)
}

// MARK: - 双源

/// GitHub 主源 + Gitee 备源：并发查、取版本更高者、单源失败回退。
/// 这些规则钉在这里，双源才不会悄悄变成「谁的响应快听谁的」。
@Suite("检查更新双源")
struct UpdateDualSourceTests {
    @Test @MainActor func bothSourcesAtSameVersionOfferBothForDownload() async throws {
        let harness = try UpdateHarness(currentVersion: "0.3.0")
        defer { harness.cleanup() }
        try harness.stub.reply("GitHub", tag: "v0.4.0", assetName: "wtmd-0.4.0.dmg", assetSize: 3_200_000)
        try harness.stub.reply("Gitee", tag: "v0.4.0", assetName: "wtmd-0.4.0.dmg", assetSize: 3_200_000)

        let checker = harness.dualChecker()
        await checker.check(force: true)

        guard case .available(let version, let sources) = checker.status else {
            Issue.record("expected available, got \(checker.status)")
            return
        }
        #expect(version == "0.4.0")
        #expect(sources.map(\.name) == ["GitHub", "Gitee"])
        #expect(sources.allSatisfy { $0.asset?.name == "wtmd-0.4.0.dmg" })
    }

    @Test @MainActor func higherVersionWinsEvenIfItComesFromTheBackup() async throws {
        let harness = try UpdateHarness(currentVersion: "0.3.0")
        defer { harness.cleanup() }
        try harness.stub.reply("GitHub", tag: "v0.4.0")
        try harness.stub.reply("Gitee", tag: "v0.5.0")

        let checker = harness.dualChecker()
        await checker.check(force: true)

        guard case .available(let version, let sources) = checker.status else {
            Issue.record("expected available, got \(checker.status)")
            return
        }
        // 版本不同步（主源落后）：听高的那个，且只带报出该版本的源
        #expect(version == "0.5.0")
        #expect(sources.map(\.name) == ["Gitee"])
    }

    @Test @MainActor func failingBackupDoesNotBreakThePrimary() async throws {
        let harness = try UpdateHarness(currentVersion: "0.3.0")
        defer { harness.cleanup() }
        try harness.stub.reply("GitHub", tag: "v0.4.0")
        // Gitee 没配回话 = 连接失败

        let checker = harness.dualChecker()
        await checker.check(force: true)

        #expect(checker.status == .available(version: "0.4.0", sources: [
            UpdateSource(name: "GitHub", asset: nil,
                         releaseURL: try #require(URL(string: "https://example.invalid/github/releases/tag/v0.4.0"))),
        ]))
    }

    @Test @MainActor func failingPrimaryFallsBackToTheBackup() async throws {
        let harness = try UpdateHarness(currentVersion: "0.3.0")
        defer { harness.cleanup() }
        try harness.stub.reply("Gitee", tag: "v0.4.0")

        let checker = harness.dualChecker()
        await checker.check(force: true)

        guard case .available(let version, let sources) = checker.status else {
            Issue.record("expected available, got \(checker.status)")
            return
        }
        #expect(version == "0.4.0")
        #expect(sources.map(\.name) == ["Gitee"])
    }

    @Test @MainActor func allSourcesFailingIsAFailure() async throws {
        let harness = try UpdateHarness(currentVersion: "0.3.0")
        defer { harness.cleanup() }

        let checker = harness.dualChecker()
        await checker.check(force: true)

        #expect(checker.status == .failed)
    }

    @Test @MainActor func giteePayloadWithoutHtmlURLStillGetsAPageFromTheTemplate() async throws {
        let harness = try UpdateHarness(currentVersion: "0.3.0")
        defer { harness.cleanup() }
        try harness.stub.replyGiteeLike(tag: "v0.4.0")

        let checker = harness.dualChecker()
        await checker.check(force: true)

        // Gitee JSON 没有 html_url / draft / prerelease：页面从模板拼，draft 宽容为 false
        #expect(checker.status == .available(version: "0.4.0", sources: [
            UpdateSource(name: "Gitee", asset: nil,
                         releaseURL: try #require(URL(string: "https://example.invalid/gitee/releases/tag/v0.4.0"))),
        ]))
    }
}

// MARK: - 命令注册

@Test func checkForUpdatesIsInTheAppSection() throws {
    let command = try #require(CommandCatalog.command(for: .checkForUpdates))
    #expect(command.section == .app)
    #expect(command.title == "检查更新…")
    #expect(command.kind.id == "app.checkForUpdates")
}
