import Foundation
import Testing
@testable import wtmd

/// 从 Finder 打开文件时「这篇该落在哪扇窗」。
///
/// 只看路由判断，不真开窗：`plan` 是纯函数，参数就是窗口此刻的三种状态。
@Suite("打开方式：文件交给哪扇窗")
@MainActor
struct OpenRequestTests {

    @Test func anUntouchedWindowTakesTheFirstFile() {
        #expect(OpenRequest.plan(
            index: 0, sameDocumentAlreadyOpen: false,
            currentWindowIsUntouched: true, owner: nil
        ) == .reuseCurrent)
    }

    /// 一张白纸上还写着没名字的字：那是没保存的稿子，不能被一个文件顶掉。
    @Test func aDraftWithUnnamedWordsIsNeverReplaced() {
        #expect(OpenRequest.plan(
            index: 0, sameDocumentAlreadyOpen: false,
            currentWindowIsUntouched: false, owner: nil
        ) == .newWindow)
    }

    /// 多选三篇：第一篇用空窗，后两篇各开一扇——否则后一篇会把前一篇顶掉。
    @Test func everyFileAfterTheFirstGetsItsOwnWindow() {
        #expect(OpenRequest.plan(
            index: 1, sameDocumentAlreadyOpen: false,
            currentWindowIsUntouched: true, owner: nil
        ) == .newWindow)
        #expect(OpenRequest.plan(
            index: 2, sameDocumentAlreadyOpen: false,
            currentWindowIsUntouched: false, owner: nil
        ) == .newWindow)
    }

    /// 这篇在别的窗里开着：跳过去，不再开第二份。
    @Test func aDocumentOpenInAnotherWindowIsRevealed() {
        let other = UUID()
        #expect(OpenRequest.plan(
            index: 0, sameDocumentAlreadyOpen: false,
            currentWindowIsUntouched: true, owner: other
        ) == .reveal(other))
    }

    /// 前台窗自己开着这篇（owner 就是它）：什么都不用做。
    @Test func openingTheSameDocumentAgainChangesNothing() {
        #expect(OpenRequest.plan(
            index: 0, sameDocumentAlreadyOpen: true,
            currentWindowIsUntouched: false, owner: UUID()
        ) == .leaveAsIs)
        // 登记表里还没写上它（刚打开、`$fileURL` 尚未落账）也不算冲突。
        #expect(OpenRequest.plan(
            index: 0, sameDocumentAlreadyOpen: true,
            currentWindowIsUntouched: false, owner: nil
        ) == .leaveAsIs)
    }

    /// 目录不是稿子：拖一个文件夹到 Dock 图标上，不该占掉一扇窗。
    @Test func onlyRealFilesAreOpenable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wtmd-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("a.md")
        try "# a".write(to: file, atomically: true, encoding: .utf8)

        #expect(OpenRequest.isEditableFile(file))
        #expect(!OpenRequest.isEditableFile(root))
        #expect(!OpenRequest.isEditableFile(root.appendingPathComponent("missing.md")))
    }
}
