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
    /// 有新版。`sources` 是所有报出这个版本的下载源（GitHub / Gitee），
    /// 首个是徽标一键装的默认源；Release 里没挂 dmg 的源 `asset` 为 nil，
    /// 界面此时退回「打开 Release 页」的老路。
    case available(version: String, sources: [UpdateSource])
    case failed
}

/// Release 里挑出来的 dmg 附件：一键更新下载的就是它。
struct UpdateAsset: Equatable {
    let url: URL
    let name: String
    let byteCount: Int

    var megabytes: String {
        byteCount >= 0 ? String(format: "%.1f MB", Double(byteCount) / 1_000_000) : ""
    }

    /// 从一组附件里挑出该装的 dmg：认 `wtmd-<版本>.dmg`（大小写不敏感），
    /// 多个时挑名字里带版本号的那个，再不行取第一个。
    static func dmg(named names: [(name: String, url: URL, size: Int)], version: String?) -> UpdateAsset? {
        let candidates = names.compactMap { piece -> UpdateAsset? in
            guard piece.name.lowercased().hasSuffix(".dmg") else { return nil }
            return UpdateAsset(url: piece.url, name: piece.name, byteCount: piece.size)
        }
        guard candidates.count > 1, let version else { return candidates.first }
        return candidates.first {
            $0.name.localizedCaseInsensitiveContains(version)
        } ?? candidates.first
    }
}

/// 一个能下载到更新的地方：名字给人看（GitHub / Gitee），asset 用来
/// 一键装，release 页是「装不动」时的退路。同一个版本可能两个源都有
/// ——挑哪个由用户点。
struct UpdateSource: Equatable {
    let name: String
    let asset: UpdateAsset?
    let releaseURL: URL
}

// MARK: - 检查器

/// 每天最多查一次发布源，发现新版本就在状态栏提示。
///
/// 三条刻意的克制：
/// 1. **不做内置下载器**——只把用户送到 Release 页或直链下载，保持零依赖；
/// 2. **失败完全静默**——写作工具不该在离线时弹窗；
/// 3. **节流**——成功后 24 小时内不再查，失败 1 小时后才重试。
///
/// 发布源可以有多个（GitHub 主源 + Gitee 备源）：检查时**并发**查、都等到
/// 结果再比较，取版本更高者；一个源挂了就用另一个，全挂才算检查失败。
/// 网络、当前版本、时钟、UserDefaults 全部注入，测试不碰真实网络。
@MainActor
final class UpdateChecker: ObservableObject {
    typealias Fetch = @Sendable (Configuration.Source) async throws -> (Data, URLResponse)

    struct Configuration {
        struct Source {
            /// 名字给人看：徽标菜单、设置页上按这个名字挑下载地。
            let name: String
            /// 「最新 release」的查询地址（GitHub 与 Gitee API v5 同构）。
            let endpoint: URL
            /// release 页地址的兜底模板（`{}` 换成 tag）。Gitee 的 JSON
            /// 不带 `html_url`，页面地址从这里拼；GitHub 自带就用它的。
            var pageTemplate: String = ""

            /// 这个源上某个 tag 的 release 页。
            func page(forTag tag: String) -> URL? {
                guard !pageTemplate.isEmpty else { return nil }
                return URL(string: pageTemplate.replacingOccurrences(of: "{}", with: tag))
            }
        }

        var currentVersion: String
        /// 所有发布源。检查时并发查全部，取版本更高的那个。
        var sources: [Source]
        /// 成功检查后的静默期。
        var interval: TimeInterval
        /// 失败后的重试间隔（比成功短，但足以避免每次启动都撞墙）。
        var retryInterval: TimeInterval

        static let `default` = Configuration(
            currentVersion: UpdateChecker.bundleVersion(),
            sources: [
                Source(
                    name: "GitHub",
                    endpoint: URL(string: "https://api.github.com/repos/TonyMistark/wtmd/releases/latest")!
                ),
                Source(
                    name: "Gitee",
                    endpoint: URL(string: "https://gitee.com/api/v5/repos/Micestark/wtmd/releases/latest")!,
                    pageTemplate: "https://gitee.com/Micestark/wtmd/releases/tag/{}"
                ),
            ],
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

        // 并发查所有源：一个源的失败不该拖垮、也不该掩盖另一个源的结果。
        // 全都失败才算检查失败；只要有活口，就按「版本更高者」出结果。
        var found: [(source: Configuration.Source, release: RemoteRelease)] = []
        await withTaskGroup(of: (Configuration.Source, Result<RemoteRelease, Error>).self) { group in
            for source in configuration.sources {
                group.addTask { [fetch] in
                    do {
                        let (data, response) = try await fetch(source)
                        guard let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode) else {
                            throw UpdateError.badResponse
                        }
                        return (source, .success(try JSONDecoder().decode(RemoteRelease.self, from: data)))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }
            for await (source, result) in group {
                if let release = try? result.get() { found.append((source, release)) }
            }
        }

        guard !found.isEmpty else {
            recordAttempt(succeeded: false)
            flash(.failed)
            return
        }
        recordAttempt(succeeded: true)
        evaluate(found)
    }

    // MARK: - 判定

    /// 源在配置里的位置；配置外的源排到最后（不该发生，兜底而已）。
    private func index(of source: Configuration.Source) -> Int {
        configuration.sources.firstIndex { $0.endpoint == source.endpoint } ?? .max
    }

    private func evaluate(_ releases: [(source: Configuration.Source, release: RemoteRelease)]) {
        guard let current = AppVersion(configuration.currentVersion) else {
            flash(.failed)
            return
        }

        // 多源可能不同步（忘了传 Gitee、或 Gitee 先挂了新版）：谁的版本高听谁的；
        // 报出同一版本的源全部带回来，用户挑一个下载。顺序按配置里的源序——
        // 并发回来的完成顺序不定，不能让它决定「首选源是谁」。
        var bestVersion: AppVersion?
        var sources: [UpdateSource] = []
        for piece in releases.sorted(by: {
            index(of: $0.source) < index(of: $1.source)
        }) {
            guard !piece.release.draft, !piece.release.prerelease,
                  let version = AppVersion(piece.release.tagName) else { continue }
            if let best = bestVersion {
                if version > best {
                    bestVersion = version
                    sources = [piece.release.updateSource(on: piece.source)]
                } else if version == best {
                    sources.append(piece.release.updateSource(on: piece.source))
                }
            } else {
                bestVersion = version
                sources = [piece.release.updateSource(on: piece.source)]
            }
        }
        // 预发布 / tag 不可解析：当作「没有可用的正式版」，不打扰用户
        guard let latest = bestVersion else {
            flash(.upToDate(version: configuration.currentVersion))
            return
        }
        if latest > current {
            status = .available(version: latest.description, sources: sources)
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

    nonisolated private static func fetchLatestRelease(from source: Configuration.Source) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: source.endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub 要求带 User-Agent，否则直接 403；Gitee 不挑，带上也无妨
        request.setValue("wtmd/\(Configuration.default.currentVersion)", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request)
    }

    nonisolated private static func bundleVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
}

// MARK: - 网络载荷

/// GitHub 与 Gitee 的 release JSON 同构但都不完整：Gitee 不带
/// `html_url`/`draft`，字段缺席一律宽容——缺了不等于坏消息。
struct RemoteRelease: Decodable {
    let tagName: String
    let htmlURL: URL?
    let draft: Bool
    let prerelease: Bool
    private let assets: [Asset]?

    init(tagName: String, htmlURL: URL? = nil, draft: Bool = false, prerelease: Bool = false, assets: [Asset]? = nil) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        htmlURL = try? container.decode(URL.self, forKey: .htmlURL)
        draft = (try? container.decode(Bool.self, forKey: .draft)) ?? false
        prerelease = (try? container.decode(Bool.self, forKey: .prerelease)) ?? false
        assets = try? container.decode([Asset].self, forKey: .assets)
    }

    /// 这个 release 在某个源上的下载入口。
    func updateSource(on source: UpdateChecker.Configuration.Source) -> UpdateSource {
        UpdateSource(
            name: source.name,
            asset: asset,
            releaseURL: htmlURL ?? source.page(forTag: tagName) ?? htmlFallback
        )
    }

    /// 模板也没配、JSON 也没带：把人带到仓库首页，总比没有强。
    private var htmlFallback: URL {
        URL(string: "https://github.com/TonyMistark/wtmd/releases")!
    }

    var asset: UpdateAsset? {
        UpdateAsset.dmg(
            named: (assets ?? []).compactMap { piece in
                guard let url = piece.downloadURL, let name = piece.name, !name.isEmpty else { return nil }
                return (name, url, piece.size ?? -1)
            },
            version: AppVersion(tagName)?.description
        )
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
        case assets
    }

    struct Asset: Decodable {
        // 附件字段缺了不算错：两个平台都会挂非 dmg 的东西，跳过它就好
        let name: String?
        let size: Int?
        let downloadURL: URL?

        enum CodingKeys: String, CodingKey {
            case name
            case size
            case downloadURL = "browser_download_url"
        }
    }
}

private enum UpdateError: Error {
    case badResponse
}
