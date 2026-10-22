import Foundation
import Testing
@testable import wtmd

/// 开发版（`swift run`，没有 bundle 版本号 → `dev`）不该把自己的现场混进
/// 用户的崩溃账本。
///
/// #147 就是这么来的：开发期一份 dev 被 `kill -9` 硬杀，下次启动把它收成
/// 「没有正常退出 · vdev」，读者在面板里看到的是「应用崩过」，还会一路
/// 提交成 GitHub issue。开发时被杀是常态，不该让用户替我们收尸。
@MainActor
struct DevelopmentCrashIsolationTests {
    @Test("开发版用另一个目录，正式版仍用 crashes")
    func developmentBuildsGetTheirOwnDirectory() {
        #expect(CrashStore.directoryName(forVersion: "dev") == "crashes-dev")
        #expect(CrashStore.directoryName(forVersion: "0.15.9") == "crashes")
        #expect(CrashStore.directoryName(forVersion: "") == "crashes-dev")
    }

    @Test("默认目录跟着版本走：dev 落在 crashes-dev 下")
    func defaultDirectoryFollowsTheVersion() {
        let expected = CrashStore.directoryName(forVersion: CrashEnvironment.appVersion)
        #expect(CrashStore.defaultDirectory.lastPathComponent == expected)
    }

    @Test("正式版的账本里，历史遗留的 vdev 报告不显示")
    func releaseStoreHidesDevelopmentReports() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReport(id: "20261020-174230-6710", version: "dev", in: root)
        try writeReport(id: "20261022-120000-aaaa", version: "0.15.9", in: root)

        let store = CrashStore(directory: root, hidesDevelopmentReports: true)
        store.reload()

        #expect(store.reports.map(\.id) == ["20261022-120000-aaaa"])
        // 只是不显示：文件还在，开发时想翻旧账还能翻到。
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("20261020-174230-6710.wtmdcrash").path
        ))
    }

    @Test("开发版自己的账本里，dev 报告照常显示")
    func developmentStoreShowsThem() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeReport(id: "20261020-174230-6710", version: "dev", in: root)

        let store = CrashStore(directory: root, hidesDevelopmentReports: false)
        store.reload()

        #expect(store.reports.map(\.id) == ["20261020-174230-6710"])
    }

    // MARK: - 造一份报告

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-devcrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeReport(id: String, version: String, in directory: URL) throws {
        let text = """
        <!-- wtmd-crash v1
        id: \(id)
        time: 2026-10-22T04:00:00Z
        kind: terminated
        version: \(version)
        system: macOS 26.6.2
        arch: arm64
        -->

        # wtmd crash report

        - Time: Oct 22, 12:00
        - Version: \(version)

        """
        try text.write(
            to: directory.appendingPathComponent("\(id).wtmdcrash"),
            atomically: true,
            encoding: .utf8
        )
    }
}
