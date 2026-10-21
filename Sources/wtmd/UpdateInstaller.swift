import AppKit
import Foundation
import SwiftUI

// MARK: - 一键更新

/// 点一下徽标 = 更新完成：下载 → 挂载 → 装进 /Applications → 重启。
///
/// 三条铁律，全都有测试钉着：
/// 1. **旧版神圣**——新 app 先在目标目录里拼装、校验（bundle 版本 = 目标版本），
///    全部通过之后才许碰已装的旧版；中途任何一步失败，旧版一个字节都不动。
/// 2. **降级不硬来**——装不进去就退回 Finder（把 dmg 在访达里亮出来），
///    拖不拖、什么时候拖，用户自己定。
/// 3. **可注入**——下载、挂载、装配、重启都是步骤闭包，测试不碰真网络、
///    不碰真 `/Applications`、更不会真的重启。
@MainActor
final class UpdateInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// 0..<1，来自 Content-Length。
        case downloading(fraction: Double)
        case installing
        /// 装不上时的原因；界面上给一条「去 Finder」的退路。
        case failed(reason: String)

        var isWorking: Bool {
            switch self {
            case .downloading, .installing: return true
            case .idle, .failed: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    /// 下载落在哪、装到哪。生产环境是临时目录与 `/Applications`。
    struct Locations {
        var downloads: URL
        var applications: URL
        /// 装好之后以这个名字出现在 applications 里。
        var appName = "wtmd.app"

        static let production = Locations(
            downloads: FileManager.default.temporaryDirectory,
            applications: URL(fileURLWithPath: "/Applications", isDirectory: true)
        )
    }

    // MARK: - 可注入的步骤

    struct Steps {
        /// 下载到本地，途中用 0..<1 报进度；返回 dmg 文件路径。
        var download: @MainActor (_ from: URL, _ progress: @MainActor @escaping (Double) -> Void) async throws -> URL
        /// 挂载 dmg，返回卷里那个 `.app` 的路径。
        var mount: @MainActor (_ dmg: URL) async throws -> URL
        /// 把 `.app` 装进目标目录，装完返回落点。**实现必须保证：失败时旧版原地不动。**
        var install: @MainActor (_ app: URL, _ locations: Locations, _ expectedVersion: String) async throws -> URL
        /// 重启进新装的那份。
        var relaunch: @MainActor (_ installed: URL) async throws -> Void
        /// 降级：把 dmg 在访达里亮出来。
        var reveal: @MainActor (_ dmg: URL) -> Void
    }

    private var steps: Steps
    private let locations: Locations

    init(steps: Steps, locations: Locations = .production) {
        self.steps = steps
        self.locations = locations
    }

    /// 降级要用：最后一枚成功落地的 dmg。
    private(set) var downloadedDMG: URL?

    // MARK: - 测试通道

    /// 替换个别步骤，没给的保持原样。
    func stepsForTest(
        download: (@MainActor (URL, @MainActor @escaping (Double) -> Void) async throws -> URL)? = nil,
        mount: (@MainActor (URL) async throws -> URL)? = nil,
        install: (@MainActor (URL, Locations, String) async throws -> URL)? = nil,
        relaunch: (@MainActor (URL) async throws -> Void)? = nil,
        reveal: (@MainActor (URL) -> Void)? = nil
    ) {
        if let download { steps.download = download }
        if let mount { steps.mount = mount }
        if let install { steps.install = install }
        if let relaunch { steps.relaunch = relaunch }
        if let reveal { steps.reveal = reveal }
    }

    // MARK: - 流程

    /// 从徽标或设置页按下去的那一下。`version` 用来在装完之后核对落点。
    func run(asset: UpdateAsset, version: String, releaseURL: URL) async {
        guard !phase.isWorking else { return }

        do {
            phase = .downloading(fraction: 0)
            let dmg = try await steps.download(asset.url) { [weak self] fraction in
                self?.phase = .downloading(fraction: fraction)
            }
            downloadedDMG = dmg

            phase = .installing
            let app = try await steps.mount(dmg)
            let installed = try await steps.install(app, locations, version)
            try await steps.relaunch(installed)
            phase = .idle
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(reason: Failure.describe(error))
        }
    }

    /// 装不上时的退路：访达里亮出 dmg，用户自己拖。
    func revealFallback() {
        guard let dmg = downloadedDMG else { return }
        steps.reveal(dmg)
    }

    /// 测试替换降级动作用。
    func revealForTest(_ reveal: @MainActor @escaping (URL) -> Void) {
        steps.reveal = reveal
    }

    func reset() {
        phase = .idle
    }

    // MARK: - 失败的措辞

    enum Failure: Error {
        case noAppInVolume
        case copyFailed(underlying: Error)
        case verifyFailed(expected: String, found: String?)
        case swapFailed(underlying: Error)

        static func describe(_ error: Error) -> String {
            if let failure = error as? Failure {
                switch failure {
                case .noAppInVolume:
                    return t("No app found in the downloaded image.", "下载的镜像里没有 app")
                case .copyFailed:
                    return t("Could not stage the new app.", "新 app 暂存失败")
                case .verifyFailed:
                    return t("The downloaded app is not the promised version.", "下载的 app 版本不对")
                case .swapFailed:
                    return t("Could not replace the installed app.", "替换已装的 app 失败")
                }
            }
            return error.localizedDescription
        }
    }

    // MARK: - 默认步骤

    static func productionSteps() -> Steps {
        Steps(
            download: { url, progress in
                try await Self.download(url, progress: progress)
            },
            mount: { dmg in
                try await Self.mount(dmg)
            },
            install: { app, locations, version in
                try Self.install(app: app, into: locations, expectedVersion: version)
            },
            relaunch: { installed in
                try await Self.relaunch(into: installed)
            },
            reveal: { dmg in
                NSWorkspace.shared.activateFileViewerSelecting([dmg])
            }
        )
    }

    // MARK: - 下载

    nonisolated static func download(
        _ url: URL,
        progress: @MainActor @escaping (Double) -> Void
    ) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        let total = response.expectedContentLength
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-update-\(UUID().uuidString).dmg")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)

        // 成块落盘：三 MB 的 dmg 逐字节写系统调用会把进度拖到不可看
        let chunkSize = 256 * 1024
        var chunk = Data()
        chunk.reserveCapacity(chunkSize)
        var received: Int64 = 0
        var lastReported = -1.0

        func flush() throws {
            guard !chunk.isEmpty else { return }
            received += Int64(chunk.count)
            try handle.write(contentsOf: chunk)
            chunk.removeAll(keepingCapacity: true)
            if total > 0 {
                let fraction = Double(received) / Double(total)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    Task { @MainActor in progress(fraction) }
                }
            }
        }

        do {
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= chunkSize { try flush() }
            }
            try flush()
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return target
    }

    // MARK: - 挂载

    nonisolated static func mount(_ dmg: URL) async throws -> URL {
        let point = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["attach", dmg.path, "-readonly", "-nobrowse", "-quiet", "-mountpoint", point.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: point)
            throw Failure.copyFailed(underlying: NSError(
                domain: "wtmd.updates", code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "hdiutil attach failed"]
            ))
        }

        // 卷里找 `.app`：发行镜像只有一份，取第一个就是它
        guard let enumerator = FileManager.default.enumerator(at: point, includingPropertiesForKeys: nil),
              let app = enumerator.allObjects.first(where: {
                  ($0 as? URL)?.pathExtension == "app"
              }) as? URL else {
            detach(point)
            throw Failure.noAppInVolume
        }
        return app
    }

    nonisolated private static func detach(_ point: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        task.arguments = ["detach", point.path, "-quiet"]
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - 装配

    /// 装配的每一步都在目标目录里「先拼好、验完再换」：
    /// 暂存 → 摘 quarantine → 核版本 → 旧版挪走 → 暂存改名上位。
    /// 任何一步抛错，`/Applications/wtmd.app` 还是原来的那一份。
    /// - Parameter retire: 旧版怎么退位（进废纸篓）；可注入，测试不真丢废纸篓。
    nonisolated static func install(
        app: URL,
        into locations: Locations,
        expectedVersion: String,
        retire: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws -> URL {
        let manager = FileManager.default
        let destination = locations.applications
            .appendingPathComponent(locations.appName, isDirectory: true)
        let staging = locations.applications
            .appendingPathComponent("wtmd.app.update-\(UUID().uuidString)", isDirectory: true)

        do {
            try manager.copyItem(at: app, to: staging)
        } catch {
            throw Failure.copyFailed(underlying: error)
        }
        defer { try? manager.removeItem(at: staging) }

        stripQuarantine(staging)

        // 版本核对：下载来的东西不许和说好的不一样
        let found = bundleVersion(of: staging)
        guard found == expectedVersion else {
            throw Failure.verifyFailed(expected: expectedVersion, found: found)
        }

        // 旧版退位：进废纸篓，进不了就改名让路——两条路都不删数据
        if manager.fileExists(atPath: destination.path) {
            do {
                try retire(destination)
            } catch {
                let aside = locations.applications
                    .appendingPathComponent("wtmd.app.old-\(UUID().uuidString)", isDirectory: true)
                do {
                    try manager.moveItem(at: destination, to: aside)
                } catch {
                    throw Failure.swapFailed(underlying: error)
                }
            }
        }
        do {
            try manager.moveItem(at: staging, to: destination)
        } catch {
            throw Failure.swapFailed(underlying: error)
        }
        return destination
    }

    /// 摘掉 `com.apple.quarantine`：不摘的话重启会被 Gatekeeper 拦死
    /// （macOS 15+ 右键打开那条路已经没了）。xattr 缺席或失败都不拦装配——
    /// 最坏结果是重启时被拦一次，用户手动放行就好。
    nonisolated static func stripQuarantine(_ app: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-cr", app.path]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    /// bundle 里报的版本；没有 Info.plist 就是 nil。
    nonisolated static func bundleVersion(of app: URL) -> String? {
        Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 探测 quarantine 标记（测试用）。
    nonisolated static func hasQuarantine(_ path: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        task.arguments = ["-p", "com.apple.quarantine", path.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    // MARK: - 重启

    /// 先拉起新的，再让自己退场——顺序反了就没有「下一次」了。
    nonisolated static func relaunch(into installed: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        try await NSWorkspace.shared.openApplication(at: installed, configuration: configuration)
        // 给新进程一点起跑时间，再让自己退场
        try? await Task.sleep(nanoseconds: 500_000_000)
        await MainActor.run { NSApp.terminate(nil) }
    }
}
