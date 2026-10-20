import AppKit
import Foundation
import SwiftUI
import Testing
@testable import wtmd

/// 打字机居中：真窗口 + 真通知。
///
/// v0.14.0 里点一下编辑器必崩（issue #135）。崩溃栈是
/// `-[NSTextView mouseDown:]` → 选区通知 → `recenter` →
/// `-[NSClipView setBoundsOrigin:]` → `NSViewHierarchyInvalidateVisibleRect` → SIGSEGV，
/// 起因是用 `clipView.animator()` 在动画组里改 bounds。这一组测试守着「不再动画、
/// 且真的居中」两件事。
///
/// 各开一扇真窗口的测试并行会互相踩（v0.11 在 CI macOS 26 上踩过），串起来跑。
@Suite(.serialized)
@MainActor
struct EditorRecenterTests {
    /// 改选区 → 通知 → 居中。这条路走完不崩，位置也得真的跟上。
    @Test func typewriterRecentersAfterASelectionChangeLikeAClick() throws {
        let rig = try makeWindowRig(typewriter: true)
        defer { rig.window.orderOut(nil) }

        rig.goTo(line: 0)
        #expect(rig.clipView.bounds.origin.y == 0)

        rig.goTo(line: 280)
        #expect(
            rig.clipView.bounds.origin.y > 2000,
            "视口没跟上光标：\(rig.clipView.bounds.origin.y)"
        )

        rig.goTo(line: 0)
        #expect(rig.clipView.bounds.origin.y == 0)
    }

    /// 关掉打字机模式：选区怎么动都不该碰滚动位置。
    @Test func typewriterOffLeavesTheViewportAlone() throws {
        let rig = try makeWindowRig(typewriter: false)
        defer { rig.window.orderOut(nil) }

        rig.goTo(line: 280)
        #expect(rig.clipView.bounds.origin.y == 0)
    }

    /// 视图被 SwiftUI 从窗口上摘掉之后再去居中：什么都不该发生。
    ///
    /// 对着已经脱钩的 clip view 改 bounds，正是「可见矩形失效时那棵视图树已经
    /// 对不上」的经典入口（issue #135）——宁可不动。
    @Test func recenteringSkipsADetachedScrollView() throws {
        let rig = try makeWindowRig(typewriter: true)
        defer { rig.window.orderOut(nil) }

        rig.goTo(line: 0)
        rig.scrollView.removeFromSuperview()

        // 光标照样可以动（通知照发），但视口不该被一条脱钩的视图带着走
        rig.goTo(line: 280)
        #expect(
            rig.clipView.bounds.origin.y == 0,
            "视图已经脱钩还改了滚动位置：\(rig.clipView.bounds.origin.y)"
        )
    }

    /// 守「不许再改成动画」：这条没有任何运行时行为可断言，只能读源码。
    @Test func centeringNeverAnimatesTheClipView() throws {
        let source = try String(contentsOf: editorSourceURL, encoding: .utf8)
        let body = try #require(recenterBody(in: source), "EditorTextView 里找不到 recenter()")

        #expect(!body.contains("animator()"), "居中又用上了动画代理：issue #135 会复发")
        #expect(!body.contains("NSAnimationContext"), "居中又包进了动画组：issue #135 会复发")
        #expect(body.contains("clipView.scroll(to:"))
    }
}

// MARK: - 辅助

@MainActor
private struct WindowRig {
    let window: NSWindow
    let coordinator: EditorTextView.Coordinator
    let body: String

    var scrollView: NSScrollView { coordinator.scrollView }
    var clipView: EditorTextView.TypewriterClipView { coordinator.clipView }

    /// 像一次点击那样把光标放到某一行：走 `setSelectedRange`，也就是
    /// `-[NSTextView mouseDown:]` 内部用的那条通知路径。
    func goTo(line: Int) {
        let location = (body as NSString).range(of: "第 \(line) 行").location
        coordinator.textView.setSelectedRange(NSRange(location: location, length: 0))
    }
}

@MainActor
private func makeWindowRig(typewriter: Bool) throws -> WindowRig {
    let editor = EditorTextView(
        text: .constant(""),
        cursorLine: .constant(0),
        pendingImageInsert: .constant(nil),
        jump: nil,
        onImagePaste: nil,
        typewriterMode: typewriter,
        focusMode: false
    )
    let coordinator = editor.makeCoordinator()
    let scrollView = coordinator.scrollView
    scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 400)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
        styleMask: [.titled, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()

    let body = (0..<300)
        .map { "第 \($0) 行 这是一段用来撑开滚动范围的中文文字" }
        .joined(separator: "\n")
    coordinator.textView.string = body
    coordinator.textView.setSelectedRange(NSRange(location: 0, length: 0))

    // 视口没有高度时居中会算出 0，后面所有断言都会假绿——先等布局落地。
    let laidOut = waitUntil { coordinator.clipView.bounds.height > 0 }
    try #require(laidOut, "滚动视图没拿到高度，这组测试就没有意义")

    return WindowRig(window: window, coordinator: coordinator, body: body)
}

/// 轮询到条件成立（别用固定 sleep：CI 上并行跑批时长短差很多）。
@MainActor
private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    return condition()
}

private var editorSourceURL: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // wtmdTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 仓库根
        .appendingPathComponent("Sources/wtmd/EditorTextView.swift")
}

/// 花括号配平，取出 `func recenter() {` 的整个函数体。
private func recenterBody(in source: String) -> String? {
    guard let start = source.range(of: "func recenter() {") else { return nil }
    var depth = 0
    var index = start.lowerBound
    var body = ""
    while index < source.endIndex {
        let character = source[index]
        body.append(character)
        if character == "{" { depth += 1 }
        if character == "}" {
            depth -= 1
            if depth == 0 { return body }
        }
        index = source.index(after: index)
    }
    return nil
}
