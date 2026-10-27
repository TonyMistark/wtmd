import Foundation
import Testing
@testable import wtmd

/// 主题卡片页的逻辑测试：筛选路由、外观徽章文案、.wttheme 安装全流程。
/// `ThemeManager` 与卡片视图都是 MainActor——套件整体跟着进主线程，
/// 省得逐个函数标隔离。
@MainActor
@Suite("ThemeCards：筛选与安装")
struct ThemeCardsTests {

    // MARK: - 脚手架

    /// 在临时目录里拼一个最小可用的 .wttheme 包（theme.json + light.css）。
    private func makeThemeFolder(
        _ name: String,
        in directory: URL,
        withThemeJSON: Bool = true
    ) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if withThemeJSON {
            let meta = #"{"name": "\#(name)", "author": "tester"}"#
            try meta.data(using: .utf8)!.write(to: folder.appendingPathComponent("theme.json"))
        }
        try "--bg: #ffffff;\n--fg: #1f2328;\n"
            .data(using: .utf8)!
            .write(to: folder.appendingPathComponent("light.css"))
        return folder
    }

    private func themeFixture(light: String?, dark: String?) -> Theme {
        Theme(id: "test.\(UUID().uuidString)", name: "t", author: "", isBuiltIn: false,
              light: light, dark: dark)
    }

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 筛选

    @Test func cardFilterRoutesBySides() {
        let both = themeFixture(light: "--bg: #fff;", dark: "--bg: #000;")
        let lightOnly = themeFixture(light: "--bg: #fff;", dark: nil)
        let darkOnly = themeFixture(light: nil, dark: "--bg: #000;")

        for theme in [both, lightOnly, darkOnly] {
            #expect(ThemeCardFilter.all.matches(theme))
        }
        #expect(!ThemeCardFilter.light.matches(both))
        #expect(ThemeCardFilter.light.matches(lightOnly))
        #expect(!ThemeCardFilter.light.matches(darkOnly))
        #expect(ThemeCardFilter.dark.matches(darkOnly))
        #expect(ThemeCardFilter.both.matches(both))
        #expect(!ThemeCardFilter.both.matches(lightOnly))
    }

    /// t() 在 static 时机求值，语言切换前后取值不定——断言取值落在中英两种
    /// 正名之内（与 base16 显示名守卫同一个防法）。
    @Test func appearanceLabelIsARealWordNotASlug() {
        let zhEN: Set<String> = ["浅色", "Light", "深色", "Dark", "浅 · 深", "Light · Dark"]
        let both = themeFixture(light: "--bg: #fff;", dark: "--bg: #000;")
        let lightOnly = themeFixture(light: "--bg: #fff;", dark: nil)
        let darkOnly = themeFixture(light: nil, dark: "--bg: #000;")

        #expect(zhEN.contains(themeAppearanceLabel(both)), "双面徽章 «\(themeAppearanceLabel(both))»")
        #expect(zhEN.contains(themeAppearanceLabel(lightOnly)), "浅色徽章 «\(themeAppearanceLabel(lightOnly))»")
        #expect(zhEN.contains(themeAppearanceLabel(darkOnly)), "深色徽章 «\(themeAppearanceLabel(darkOnly))»")
    }

    // MARK: - 安装

    @Test func uniqueFolderNameSkipsTakenNames() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ThemeManager.uniqueFolderName(for: "暖沙", in: dir) == "暖沙")
        try makeThemeFolder("暖沙", in: dir)
        #expect(ThemeManager.uniqueFolderName(for: "暖沙", in: dir) == "暖沙 2")
        try makeThemeFolder("暖沙 2", in: dir)
        #expect(ThemeManager.uniqueFolderName(for: "暖沙", in: dir) == "暖沙 3")
    }

    @Test func copyThemePackageInstallsALoadableCopy() throws {
        let root = try scratchDirectory()
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try makeThemeFolder("暖沙", in: root)
        let installed = try ThemeManager.copyThemePackage(from: source, into: target)

        #expect(installed.lastPathComponent == "暖沙")
        let loaded = ThemeFormat.loadFolder(installed)
        #expect(loaded != nil)
        #expect(loaded?.name == "暖沙")
        #expect(loaded?.author == "tester")
    }

    @Test func copyThemePackageRejectsNonThemes() throws {
        let root = try scratchDirectory()
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 没有 theme.json 的普通文件夹：整体拒绝，不装半套
        let plain = try makeThemeFolder("plain", in: root, withThemeJSON: false)
        #expect(throws: ThemeInstallError.self) {
            try ThemeManager.copyThemePackage(from: plain, into: target)
        }
        // 名字撞了自动挪到序号名，不覆盖已装的
        let source = try makeThemeFolder("暖沙", in: root)
        _ = try ThemeManager.copyThemePackage(from: source, into: target)
        let second = try ThemeManager.copyThemePackage(from: source, into: target)
        #expect(second.lastPathComponent == "暖沙 2")
        #expect(ThemeFormat.loadFolder(second) != nil)
    }

    @Test func invalidPackageErrorExplainsItself() {
        let error = ThemeInstallError.invalidPackage
        #expect(!(error.errorDescription ?? "").isEmpty)
    }
}
