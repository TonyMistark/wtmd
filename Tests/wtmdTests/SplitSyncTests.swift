import Foundation
import Testing
@testable import wtmd

/// 判权：谁在动、另一边该不该跟着动。
struct SyncScrollStateTests {
    @Test func theFirstMoveTakesControl() {
        var state = SyncScrollState()
        let accepted = state.accept(.editor, at: 100)
        #expect(accepted)
        #expect(state.owner == .editor)
    }

    @Test func theSameSideKeepsControlWhileItKeepsMoving() {
        var state = SyncScrollState()
        _ = state.accept(.editor, at: 100)
        let accepted = state.accept(.editor, at: 100.9)
        #expect(accepted)
    }

    /// 一方驱动另一方之后，另一边的回报是回声——丢掉，否则两边互相推着抖。
    @Test func theOtherSideIsEchoInsideTheWindow() {
        var state = SyncScrollState()
        _ = state.accept(.editor, at: 100)
        let insideWindow = state.accept(.preview, at: 100.1)
        let atTheEdge = state.accept(.preview, at: 100 + SyncScrollState.hold - 0.01)
        #expect(insideWindow == false)
        #expect(atTheEdge == false)
    }

    /// 窗口一过，读者真的去滚另一边了，控制权归它。
    @Test func theOtherSideTakesOverAfterTheWindow() {
        var state = SyncScrollState()
        _ = state.accept(.editor, at: 100)
        let accepted = state.accept(.preview, at: 100 + SyncScrollState.hold + 0.01)
        #expect(accepted)
        #expect(state.owner == .preview)
    }

    @Test func resetForgetsEverything() {
        var state = SyncScrollState()
        _ = state.accept(.preview, at: 100)
        state.reset()
        #expect(state.owner == nil)
        let accepted = state.accept(.editor, at: 100.05)
        #expect(accepted)
    }
}

private final class TestClock {
    var now: TimeInterval = 0
}

/// 控制器：只做翻译（谁动了 → 另一侧该滚到第几行），不碰视图。
@MainActor
struct SplitSyncControllerTests {
    private func makeController() -> (SplitSyncController, TestClock) {
        let clock = TestClock()
        let controller = SplitSyncController(now: { clock.now })
        controller.isActive = true
        return (controller, clock)
    }

    @Test func nothingHappensOutsideSplitMode() {
        let clock = TestClock()
        let controller = SplitSyncController(now: { clock.now })
        controller.editorMoved(to: 7)
        #expect(controller.previewScroll == nil)
        controller.previewMoved(to: 7)
        #expect(controller.editorReveal == nil)
    }

    @Test func editorMoveAsksThePreviewToScroll() {
        let (controller, _) = makeController()
        controller.editorMoved(to: 7)
        #expect(controller.previewScroll?.line == 7)
        #expect(controller.editorReveal == nil)
    }

    @Test func previewMoveAsksTheEditorToReveal() {
        let (controller, _) = makeController()
        controller.previewMoved(to: 12)
        #expect(controller.editorReveal?.line == 12)
        #expect(controller.previewScroll == nil)
    }

    /// 停在原地打字：光标行没变，不该反复发滚动请求（滚动事件是每帧的）。
    @Test func stayingOnTheSameLineIsNotRepeated() {
        let (controller, clock) = makeController()
        controller.editorMoved(to: 7)
        let first = controller.previewScroll
        clock.now += 1
        controller.editorMoved(to: 7)
        #expect(controller.previewScroll == first)
    }

    /// 每一次真的换行都算新请求：id 必须变，否则视图会以为「这条处理过了」。
    @Test func eachNewLineGetsAFreshRequest() {
        let (controller, clock) = makeController()
        controller.editorMoved(to: 7)
        let first = controller.previewScroll
        clock.now += 1
        controller.editorMoved(to: 8)
        #expect(controller.previewScroll?.line == 8)
        #expect(controller.previewScroll?.id != first?.id)
    }

    /// 预览的回声不能反过来把源码拽走。
    @Test func echoFromThePreviewIsIgnored() {
        let (controller, clock) = makeController()
        controller.editorMoved(to: 7)
        clock.now += 0.1
        controller.previewMoved(to: 30)
        #expect(controller.editorReveal == nil)
    }

    @Test func negativeLinesAreIgnored() {
        let (controller, _) = makeController()
        controller.editorMoved(to: -1)
        #expect(controller.previewScroll == nil)
        controller.previewMoved(to: -1)
        #expect(controller.editorReveal == nil)
    }

    /// 退出分栏要清干净：切回来时不能重放上一次的位置。
    @Test func leavingSplitClearsPendingRequests() {
        let (controller, _) = makeController()
        controller.editorMoved(to: 7)
        #expect(controller.previewScroll != nil)
        controller.isActive = false
        #expect(controller.previewScroll == nil)
        #expect(controller.editorReveal == nil)
    }

    /// 重新进入分栏后，同一个行号要能再次触发（计数器不能被清回 0 撞上旧 id）。
    @Test func reenteringSplitCanRequestTheSameLineAgain() {
        let (controller, clock) = makeController()
        controller.editorMoved(to: 7)
        let first = controller.previewScroll
        controller.isActive = false
        clock.now += 1
        controller.isActive = true
        controller.editorMoved(to: 7)
        #expect(controller.previewScroll?.line == 7)
        #expect(controller.previewScroll?.id != first?.id)
    }
}
