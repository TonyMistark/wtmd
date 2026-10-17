import Foundation
import SwiftUI

// MARK: - 版本号

/// 宽松语义化版本：`v0.4.0`、`0.4`、`0.4.0-beta.2` 都认。
///
/// 比较规则按 semver 的本意做最小实现：数字段逐位比（缺位补 0），
/// 预发布版**低于**同号正式版（`0.4.0-beta` < `0.4.0`），
/// 预发布标识里数字段小于字母段（`beta.2` < `beta.x`）。
struct AppVersion: Comparable, Equatable, CustomStringConvertible {
    let core: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        // 构建元数据（+build.5）不参与比较
        if let plus = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plus])
        }
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".").map { Int($0) }
        // 任一数字段不是整数就整串无效——宁可漏提示，也不误报「有新版」
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        core = numbers.compactMap { $0 }
        if parts.count > 1 {
            let identifiers = parts[1].split(separator: ".").map(String.init)
            guard !identifiers.isEmpty else { return nil }
            prerelease = identifiers
        } else {
            prerelease = []
        }
    }

    var description: String {
        let base = core.map(String.init).joined(separator: ".")
        return prerelease.isEmpty ? base : "\(base)-\(prerelease.joined(separator: "."))"
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }
        // 数字段相同：有预发布标识的那一方更小
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?):
                return leftNumber < rightNumber
            case (_?, nil):
                return true      // 数字标识 < 字母标识
            case (nil, _?):
                return false
            default:
                return left < right
            }
        }
        // 前缀相同，标识更少的那个更小（0.4.0-beta < 0.4.0-beta.1）
        return lhs.prerelease.count < rhs.prerelease.count
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

// MARK: - 检查结果

/// 供 UI 直接消费的状态。`upToDate` 与 `failed` 是「一次性反馈」，
/// 短暂展示后会自动回到 `idle`；`available` 会一直留着，直到用户升级。
enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(version: String)
    case available(version: String, releaseURL: URL)
    case failed
}

// MARK: - 检查器

/// 每天最多查一次 GitHub Release，发现新版本就在状态栏提示。
///
/// 三条刻意的克制：
/// 1. **不做内置下载器**——只把用户送到 Release 页，保持零依赖；
/// 2. **失败完全静默**——写作工具不该在离线时弹窗；
/// 3. **节流**——成功后 24 小时内不再查，失败 1 小时后才重试。
///
/// 网络、当前版本、时钟、UserDefaults 全部注入，测试不碰真实网络。
@MainActor
final class UpdateChecker: ObservableObject {
    typealias Fetch = () async throws -> (Data, URLResponse)

    struct Configuration {
        var currentVersion: String
        var endpoint: URL
        /// 成功检查后的静默期。
        var interval: TimeInterval
        /// 失败后的重试间隔（比成功短，但足以避免每次启动都撞墙）。
        var retryInterval: TimeInterval

        static let `default` = Configuration(
            currentVersion: UpdateChecker.bundleVersion(),
            endpoint: URL(string: "https://api.github.com/repos/TonyMistark/wtmd/releases/latest")!,
            interval: 24 * 60 * 60,
            retryInterval: 60 * 60
        )
    }

    @Published private(set) var status: UpdateStatus = .idle

    /// 一次性反馈留在状态栏上的时长。
    private static let flashDuration: TimeInterval = 4

    private let configuration: Configuration
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: Fetch
    private var resetTask: Task<Void, Never>?

    private enum Key {
        static let lastCheck = "wtmd.updates.lastCheck"
        static let lastCheckSucceeded = "wtmd.updates.lastCheckOK"
    }

    init(
        configuration: Configuration = .default,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        fetch: @escaping Fetch = UpdateChecker.fetchLatestRelease
    ) {
        self.configuration = configuration
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
    }

    var isChecking: Bool { status == .checking }

    var currentVersion: String { configuration.currentVersion }

    /// 启动时调用：距上次检查够久才真的发请求。
    func checkIfDue() async {
        await check(force: false)
    }

    /// 手动「检查更新…」走这里，忽略节流。
    func check(force: Bool) async {
        guard status != .checking else { return }
        guard force || isDue else { return }

        resetTask?.cancel()
        status = .checking

        do {
            let (data, response) = try await fetch()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw UpdateError.badResponse
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            recordAttempt(succeeded: true)
            evaluate(release)
        } catch {
            recordAttempt(succeeded: false)
            flash(.failed)
        }
    }

    // MARK: - 判定

    private func evaluate(_ release: GitHubRelease) {
        guard !release.draft, !release.prerelease,
              let latest = AppVersion(release.tagName) else {
            // 预发布或 tag 不可解析：当作「没有可用的正式版」，不打扰用户
            flash(.upToDate(version: configuration.currentVersion))
            return
        }
        guard let current = AppVersion(configuration.currentVersion) else {
            flash(.failed)
            return
        }
        if latest > current {
            status = .available(version: latest.description, releaseURL: release.htmlURL)
        } else {
            flash(.upToDate(version: current.description))
        }
    }

    // MARK: - 节流

    private var isDue: Bool {
        guard let last = defaults.object(forKey: Key.lastCheck) as? Double else { return true }
        let succeeded = defaults.bool(forKey: Key.lastCheckSucceeded)
        let interval = succeeded ? configuration.interval : configuration.retryInterval
        return now().timeIntervalSince1970 - last >= interval
    }

    private func recordAttempt(succeeded: Bool) {
        defaults.set(now().timeIntervalSince1970, forKey: Key.lastCheck)
        defaults.set(succeeded, forKey: Key.lastCheckSucceeded)
    }

    // MARK: - 一次性反馈

    private func flash(_ value: UpdateStatus) {
        status = value
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flashDuration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.status == value else { return }
            self.status = .idle
        }
    }

    // MARK: - 默认网络实现

    nonisolated private static func fetchLatestRelease() async throws -> (Data, URLResponse) {
        var request = URLRequest(url: Configuration.default.endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub 要求带 User-Agent，否则直接 403
        request.setValue("wtmd/\(Configuration.default.currentVersion)", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request)
    }

    nonisolated private static func bundleVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}

// MARK: - 网络载荷

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}

private enum UpdateError: Error {
    case badResponse
}
