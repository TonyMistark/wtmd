import AppKit
import Foundation
import Testing

@testable import wtmd

// MARK: - 挑 dmg

/// Release 里挂的东西五花八门（zip、sig、txt），能装的只有那枚 dmg。
@Suite("从附件里挑 dmg")
struct UpdateAssetTests {
    private func asset(_ name: String, size: Int = 3_000_000) -> (name: String, url: URL, size: Int) {
        (
            name,
            URL(string: "https://example.invalid/download/\(name)")!,
            size
        )
    }

    @Test("zip、sig 都不算，只认 dmg")
    func picksTheDMG() {
        let picked = UpdateAsset.dmg(named: [
            asset("source.tar.gz"), asset("wtmd-0.16.0.dmg"), asset("checksums.txt"),
        ], version: "0.16.0")
        #expect(picked?.name == "wtmd-0.16.0.dmg")
        #expect(picked?.url.absoluteString == "https://example.invalid/download/wtmd-0.16.0.dmg")
    }

    @Test("多枚 dmg 时挑名字带版本号的那个")
    func prefersTheVersionedOne() {
        let picked = UpdateAsset.dmg(named: [
            asset("wtmd-legacy.dmg"), asset("wtmd-0.16.0.dmg"),
        ], version: "0.16.0")
        #expect(picked?.name == "wtmd-0.16.0.dmg")
    }

    @Test("没有 dmg 就是 nil——界面退回打开 Release 页")
    func nothingToPick() {
        #expect(UpdateAsset.dmg(named: [asset("source.zip")], version: "0.16.0") == nil)
        #expect(UpdateAsset.dmg(named: [], version: "0.16.0") == nil)
    }

    @Test("大小按 MB 报")
    func sizesInMegabytes() {
        let picked = UpdateAsset.dmg(named: [asset("wtmd-0.16.0.dmg", size: 3_100_000)], version: nil)
        #expect(picked?.megabytes == "3.1 MB")
    }
}

// MARK: - 一键更新的流程

/// 步骤全换成记账替身：流程只负责「按顺序走、把进度摆出来、
/// 失败了别再往下走」——真下载真挂载交给生产实现。
@Suite("一键更新的流程", .serialized)
@MainActor
struct UpdateInstallerFlowTests {
    private func makeInstaller() -> UpdateInstaller {
        UpdateInstaller(steps: UpdateInstaller.Steps(
            download: { _, _ in throw NSError(domain: "unwired", code: 1) },
            mount: { _ in throw NSError(domain: "unwired", code: 1) },
            install: { _, _, _ in throw NSError(domain: "unwired", code: 1) },
            relaunch: { _ in throw NSError(domain: "unwired", code: 1) },
            reveal: { _ in }
        ))
    }

    private let asset = UpdateAsset(
        url: URL(string: "https://example.invalid/wtmd-0.16.0.dmg")!,
        name: "wtmd-0.16.0.dmg",
        byteCount: 3_100_000
    )

    @Test("全程按顺序：下载 → 挂载 → 装配 → 重启，进度摆在原地")
    func runsTheStepsInOrder() async {
        let installer = makeInstaller()
        var order: [String] = []
        installer.stepsForTest(
            download: { _, progress in
                order.append("download")
                progress(0.4)
                // 松开主 actor，让观察的那边看得到这一拍
                try? await Task.sleep(nanoseconds: 30_000_000)
                progress(1.0)
                return URL(fileURLWithPath: "/tmp/fake.dmg")
            },
            mount: { _ in order.append("mount"); return URL(fileURLWithPath: "/tmp/fake.app") },
            install: { _, _, _ in order.append("install"); return URL(fileURLWithPath: "/Applications/wtmd.app") },
            relaunch: { _ in order.append("relaunch") }
        )

        var fractions: [Double] = []
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for _ in 0..<100 {
                    if case .downloading(let fraction) = installer.phase { fractions.append(fraction) }
                    if order.count == 4 { return }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
            }
            await installer.run(asset: asset, version: "0.16.0", releaseURL: URL(fileURLWithPath: "/"))
            group.cancelAll()
        }

        #expect(order == ["download", "mount", "install", "relaunch"])
        #expect(fractions.contains(0.4))
        #expect(installer.phase == .idle)
    }

    @Test("装配失败就停：不重启，失败原因摆出来")
    func stopsWhenInstallFails() async {
        let installer = makeInstaller()
        installer.stepsForTest(
            download: { _, _ in URL(fileURLWithPath: "/tmp/fake.dmg") },
            mount: { _ in URL(fileURLWithPath: "/tmp/fake.app") },
            install: { _, _, _ in throw UpdateInstaller.Failure.verifyFailed(expected: "0.16.0", found: "0.15.0") },
            relaunch: { _ in Issue.record("装配失败了还重启？") }
        )

        await installer.run(asset: asset, version: "0.16.0", releaseURL: URL(fileURLWithPath: "/"))

        guard case .failed(let reason) = installer.phase else {
            Issue.record("该停在失败，而不是 \(installer.phase)")
            return
        }
        #expect(reason == t("The downloaded app is not the promised version.", "下载的 app 版本不对"))
    }

    @Test("下载失败：连挂载都不碰，dmg 也没有")
    func stopsWhenDownloadFails() async {
        let installer = makeInstaller()
        installer.stepsForTest(
            download: { _, _ in throw URLError(.notConnectedToInternet) },
            mount: { _ in Issue.record("下载失败不该挂载"); return URL(fileURLWithPath: "/") },
            install: { _, _, _ in Issue.record("下载失败不该装配"); return URL(fileURLWithPath: "/") },
            relaunch: { _ in Issue.record("下载失败不该重启") }
        )

        await installer.run(asset: asset, version: "0.16.0", releaseURL: URL(fileURLWithPath: "/"))
        #expect(installer.downloadedDMG == nil)
        guard case .failed = installer.phase else {
            Issue.record("该停在失败")
            return
        }
    }

    @Test("正在干的时候再点是无害的：不会跑第二条流水线")
    func ignoresReentry() async {
        let installer = makeInstaller()
        // download 停在闸门里，等测试放行；这些旗标全在 MainActor 上读写，
        // 与闭包同隔离，不用锁。
        var enteredDownload = false
        var downloadEntries = 0
        var released = false
        installer.stepsForTest(
            download: { _, _ in
                enteredDownload = true
                downloadEntries += 1
                let gateOpenedAt = Date()
                while !released {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    // 截止时间：重入保护被摘掉时这条流水线永远等不到放行
                    if Date().timeIntervalSince(gateOpenedAt) > 5 { return URL(fileURLWithPath: "/tmp/fake.dmg") }
                }
                return URL(fileURLWithPath: "/tmp/fake.dmg")
            },
            mount: { _ in URL(fileURLWithPath: "/tmp/fake.app") },
            install: { _, _, _ in URL(fileURLWithPath: "/Applications/wtmd.app") },
            relaunch: { _ in }
        )

        let first = Task { await installer.run(asset: asset, version: "0.16.0", releaseURL: URL(fileURLWithPath: "/")) }
        let startedAt = Date()
        while !enteredDownload {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if Date().timeIntervalSince(startedAt) > 5 {
                Issue.record("下载迟迟没有开始——重入保护可能被摘了")
                released = true
                _ = await first.result
                return
            }
        }
        // 流水线还在跑：第二次按下去应当被无视
        await installer.run(asset: asset, version: "0.16.0", releaseURL: URL(fileURLWithPath: "/"))
        released = true
        _ = await first.result
        #expect(downloadEntries == 1, "第二次按下去不该再进下载")
        #expect(installer.phase == .idle)
    }

    @Test("失败后的退路：把下载下来的 dmg 在访达里亮出来")
    func revealsTheDownload() async {
        let installer = makeInstaller()
        installer.stepsForTest(
            download: { _, _ in URL(fileURLWithPath: "/tmp/fake.dmg") },
            mount: { _ in throw NSError(domain: "x", code: 1) },
            install: { _, _, _ in URL(fileURLWithPath: "/") },
            relaunch: { _ in }
        )
        var revealed: [URL] = []
        installer.revealForTest { revealed.append($0) }

        await installer.run(asset: asset, version: "0.16.0", releaseURL: URL(fileURLWithPath: "/"))
        installer.revealFallback()
        #expect(revealed.map(\.path) == ["/tmp/fake.dmg"])

        installer.reset()
        #expect(installer.phase == .idle)
    }
}

// MARK: - 装配（真文件系统）

/// 装配是安全的关键：先拼好、验完才许碰旧版。这几条用真临时目录跑，
/// `/Applications` 绝不出现在测试里。
@Suite("装配与退位")
struct UpdateInstallerSwapTests {
    /// 拼一个最小可用的 .app：Contents/Info.plist + 可执行文件。
    private func makeApp(version: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true
        )
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>CFBundleShortVersionString</key><string>\(version)</string>
            <key>CFBundleIdentifier</key><string>com.example.fake</string>
        </dict></plist>
        """
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try Data("#!/bin/sh\n".utf8).write(to: url.appendingPathComponent("Contents/MacOS/fake"))
    }

    private func makeSandbox() throws -> UpdateInstaller.Locations {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return UpdateInstaller.Locations(
            downloads: root.appendingPathComponent("Downloads", isDirectory: true),
            applications: root.appendingPathComponent("Applications", isDirectory: true)
        )
    }

    @Test("顺利换新：暂存上位，旧版退位，现场不留暂存目录")
    func swapsInTheNewApp() throws {
        let locations = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: locations.applications.deletingLastPathComponent()) }

        let mounted = locations.applications.appendingPathComponent("mounted/Fake.app", isDirectory: true)
        try makeApp(version: "0.16.0", at: mounted)
        let old = locations.applications.appendingPathComponent("wtmd.app", isDirectory: true)
        try makeApp(version: "0.15.6", at: old)

        let recorder = RetireRecorder()
        let installed = try UpdateInstaller.install(
            app: mounted, into: locations, expectedVersion: "0.16.0",
            retire: { url in
                recorder.record(url)
                // 与废纸篓等价：旧版真的离开原位，暂存才能改名上位
                try FileManager.default.moveItem(
                    at: url,
                    to: url.deletingLastPathComponent()
                        .appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
                )
            }
        )

        #expect(installed == old)
        #expect(UpdateInstaller.bundleVersion(of: installed) == "0.16.0")
        #expect(recorder.recorded == [old])
        // 暂存目录不留尸
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: locations.applications.path)
        #expect(!leftovers.contains { $0.contains("update-") })
    }

    /// `retire` 闭包是 `@Sendable` 的：直接改捕获的局部变量在 Swift 6 下会报，
    /// 用一个小盒子记账。
    private final class RetireRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        var recorded: [URL] { lock.lock(); defer { lock.unlock() }; return urls }

        func record(_ url: URL) {
            lock.lock()
            urls.append(url)
            lock.unlock()
        }
    }

    @Test("版本不对：抛错，旧版原地不动，暂存清干净")
    func refusesTheWrongVersion() throws {
        let locations = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: locations.applications.deletingLastPathComponent()) }

        let mounted = locations.applications.appendingPathComponent("mounted/Fake.app", isDirectory: true)
        try makeApp(version: "0.15.0", at: mounted)
        let old = locations.applications.appendingPathComponent("wtmd.app", isDirectory: true)
        try makeApp(version: "0.15.6", at: old)

        #expect(throws: UpdateInstaller.Failure.self) {
            try UpdateInstaller.install(
                app: mounted, into: locations, expectedVersion: "0.16.0",
                retire: { url in
                    // 真让路：核对一旦被摘，换新就会成功，这条测试就得红
                    try FileManager.default.moveItem(
                        at: url,
                        to: url.deletingLastPathComponent()
                            .appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
                    )
                }
            )
        }
        #expect(UpdateInstaller.bundleVersion(of: mounted) == "0.15.0")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: locations.applications.path)
        #expect(!leftovers.contains { $0.contains("update-") })
    }

    @Test("没有 Info.plist 的东西也过不了版本核对")
    func refusesABrokenBundle() throws {
        let locations = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: locations.applications.deletingLastPathComponent()) }

        let mounted = locations.applications.appendingPathComponent("mounted/Broken.app", isDirectory: true)
        try FileManager.default.createDirectory(at: mounted, withIntermediateDirectories: true)
        let old = locations.applications.appendingPathComponent("wtmd.app", isDirectory: true)
        try makeApp(version: "0.15.6", at: old)

        #expect(throws: UpdateInstaller.Failure.self) {
            try UpdateInstaller.install(
                app: mounted, into: locations, expectedVersion: "0.16.0",
                retire: { url in
                    try FileManager.default.moveItem(
                        at: url,
                        to: url.deletingLastPathComponent()
                            .appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
                    )
                }
            )
        }
    }

    @Test("退位失败还有第二条路：改名让路，照样换新")
    func fallsBackToRenamingAside() throws {
        let locations = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: locations.applications.deletingLastPathComponent()) }

        let mounted = locations.applications.appendingPathComponent("mounted/Fake.app", isDirectory: true)
        try makeApp(version: "0.16.0", at: mounted)
        let old = locations.applications.appendingPathComponent("wtmd.app", isDirectory: true)
        try makeApp(version: "0.15.6", at: old)

        let installed = try UpdateInstaller.install(
            app: mounted, into: locations, expectedVersion: "0.16.0",
            retire: { _ in throw NSError(domain: "trash", code: 1) }
        )
        #expect(UpdateInstaller.bundleVersion(of: installed) == "0.16.0")
        // 旧版还在 applications 目录里（改了名让路），没被删
        let entries = try FileManager.default.contentsOfDirectory(atPath: locations.applications.path)
        #expect(entries.contains { $0.hasPrefix("wtmd.app.old-") })
    }
}

// MARK: - quarantine

@Suite("quarantine 的摘除")
struct QuarantineTests {
    @Test("带 quarantine 的目录，摘完就没有了")
    func stripsTheAttribute() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-quarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        seed.arguments = ["-w", "com.apple.quarantine", "0083;0000;test;", dir.path]
        try seed.run(); seed.waitUntilExit()
        #expect(seed.terminationStatus == 0, "测试前置失败：quarantine 没种上")

        UpdateInstaller.stripQuarantine(dir)
        #expect(!UpdateInstaller.hasQuarantine(dir), "摘完不该再有 quarantine")
    }
}

// MARK: - 装配（源码级）

/// 徽标与设置页都接在同一个动作上：有 dmg 一键装、没有就开下载页。
@Suite("一键更新的装配")
struct UpdateInstallerAssemblyTests {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("徽标点下去走的是一键更新，不再直接开浏览器")
    func theBadgeInstalls() throws {
        let content = try source("ContentView.swift")
        #expect(content.contains("installer.run(asset:"))
        #expect(content.contains("case .available(let version, let url, let asset):"))
    }

    @Test("设置页也有一条更新的动作")
    func settingsHasAnAction() throws {
        let pages = try source("SettingsPages.swift")
        #expect(pages.contains("installer.run(asset:"))
        #expect(pages.contains("revealFallback()"))
    }

    @Test("应用环境里装着 installer，并注入了视图环境")
    func theInstallerIsWired() throws {
        let model = try source("WindowModel.swift")
        #expect(model.contains("UpdateInstaller(steps: UpdateInstaller.productionSteps())"))
        let app = try source("wtmdApp.swift")
        #expect(app.contains("environmentObject(shared.installer)"))
    }
}

// MARK: - 重启

/// 「装完退出，再也没打开」的守卫（#195）。
///
/// 真机探针实证：新版本已经躺在同一个路径上、bundle id 也一模一样，直接
/// `NSWorkspace.openApplication` 只会激活「正在退场的自己」——回调里拿到的 pid
/// 就是自己，`launch` 日志只有一条，新进程一个都没起。所以重启必须是
/// **等我们退干净，再由别的进程 open**：一个不 wait 的 `/bin/sh` 子进程，
/// 父进程退出后它被 launchd 收养，等 pid 消失再开新版。
@Suite("重启：退出之后再打开")
struct UpdateRelaunchTests {
    private var installerSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/wtmd/UpdateInstaller.swift")
    }

    @Test("重启用的是「等本进程退出后 open」，而不是当场 open")
    func theScriptWaitsForTheOldProcessToGoAway() {
        let app = URL(fileURLWithPath: "/Applications/wtmd.app")
        let script = UpdateInstaller.relaunchScript(waitingFor: 4242, opening: app)

        #expect(script.contains("kill -0 4242"), "脚本没有等旧进程退出——那就又回到「激活自己」了")
        #expect(
            script.contains("/usr/bin/open -n '/Applications/wtmd.app'"),
            "脚本里没有 open 新版（或没带 -n）"
        )
        #expect(
            script.contains("[ $i -lt 75 ]"),
            "等待没有上限——旧进程万一卡着不退，新版就永远不开"
        )
    }

    @Test("带空格的路径整段加引号，不会被拆成两个参数")
    func spacesSurviveTheShell() {
        let path = "/Users/ice/My Apps/wtmd.app"
        #expect(UpdateInstaller.shellQuoted(path) == "'/Users/ice/My Apps/wtmd.app'")
        let script = UpdateInstaller.relaunchScript(waitingFor: 1, opening: URL(fileURLWithPath: path))
        #expect(script.contains("'/Users/ice/My Apps/wtmd.app'"))
    }

    @Test("路径里有单引号也转义得住")
    func quotesSurviveTheShell() {
        #expect(
            UpdateInstaller.shellQuoted("/tmp/it's here/wtmd.app") == "'/tmp/it'\\''s here/wtmd.app'"
        )
    }

    @Test("relaunch 走派生重启器这条路，并留了强制新实例的退路")
    func relaunchSpawnsTheHelper() throws {
        // 只看代码：注释里写着「不能直接 openApplication」是在解释原因，不该判红。
        let source = try String(contentsOf: installerSource, encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let cut = line.range(of: "//") else { return String(line) }
                return String(line[..<cut.lowerBound])
            }
            .joined(separator: "\n")

        #expect(code.contains("spawnRelauncher("), "重启没走「退出后再打开」那条路")
        #expect(
            code.contains("createsNewApplicationInstance = true"),
            "连退路都没留：子进程起不来时得强制新实例，不能什么都不开"
        )
    }
}
