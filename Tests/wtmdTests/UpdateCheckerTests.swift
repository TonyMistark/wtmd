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
    var calls = 0
    var now = Date(timeIntervalSince1970: 1_700_000_000)
    var result: Result<(Data, URLResponse), Error> = .failure(URLError(.notConnectedToInternet))

    func reply(tag: String, draft: Bool = false, prerelease: Bool = false, status: Int = 200) throws {
        let url = try #require(URL(string: "https://github.com/TonyMistark/wtmd/releases/tag/\(tag)"))
        let body: [String: Any] = [
            "tag_name": tag,
            "html_url": url.absoluteString,
            "draft": draft,
            "prerelease": prerelease,
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/latest")!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )
        )
        result = .success((data, response))
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
        result = .success((Data(text.utf8), response))
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

    func checker(interval: TimeInterval = 24 * 3600, retryInterval: TimeInterval = 3600) -> UpdateChecker {
        let stub = stub
        return UpdateChecker(
            configuration: UpdateChecker.Configuration(
                currentVersion: currentVersion,
                endpoint: URL(string: "https://example.invalid/latest")!,
                interval: interval,
                retryInterval: retryInterval
            ),
            defaults: defaults,
            now: { stub.now },
            fetch: {
                stub.calls += 1
                return try stub.result.get()
            }
        )
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

    let expectedURL = try #require(URL(string: "https://github.com/TonyMistark/wtmd/releases/tag/v0.4.0"))
    #expect(checker.status == .available(version: "0.4.0", releaseURL: expectedURL))
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
    #expect(checker.status == .available(version: "0.4.0", releaseURL: try #require(URL(string: "https://github.com/TonyMistark/wtmd/releases/tag/v0.4.0"))))
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

// MARK: - 命令注册

@Test func checkForUpdatesIsInTheAppSection() throws {
    let command = try #require(CommandCatalog.command(for: .checkForUpdates))
    #expect(command.section == .app)
    #expect(command.title == "检查更新…")
    #expect(command.kind.id == "app.checkForUpdates")
}
