import AppKit
import SwiftUI

/// One window's content: its own document + folder + palette, the app's settings,
/// and the hook that tells the app which window is in front.
///
/// `ContentView` itself stays unchanged in shape — it keeps reading its stores
/// from the environment. What changes is who puts them there: each window root
/// injects its own `DocumentStore` / `WorkspaceStore`, and the shared settings.
struct WindowRoot: View {
    @StateObject private var model: WindowModel
    private let coordinator: WindowCoordinator

    init(model: WindowModel, coordinator: WindowCoordinator) {
        _model = StateObject(wrappedValue: model)
        self.coordinator = coordinator
    }

    var body: some View {
        ContentView(paletteVisible: $model.paletteVisible, coordinator: coordinator)
            .environmentObject(model.store)
            .environmentObject(model.workspace)
            .environmentObject(model.shared.writing)
            .environmentObject(model.shared.typesetting)
            .environmentObject(model.shared.updates)
            .environmentObject(model.shared.overrides)
            .environmentObject(model.shared.themeManager)
            // 菜单命令靠这个值找到「该对谁下手」。
            .focusedSceneValue(\.windowModel, model)
            .background {
                ZStack {
                    WindowBridge(model: model, coordinator: coordinator)
                    OpenWindowBridge(coordinator: coordinator)
                }
            }
            .frame(minWidth: 760, minHeight: 500)
    }
}

/// 窗口场景里唯一需要和 AppKit 打交道的地方：抓住 `NSWindow`（前台判断、
/// 关闭通知），以及把 `openWindow` 交给协调器。两者在 SwiftUI 里都拿不到。
private struct WindowBridge: NSViewRepresentable {
    let model: WindowModel
    let coordinator: WindowCoordinator

    func makeCoordinator() -> BridgeCoordinator {
        BridgeCoordinator(model: model, coordinator: coordinator)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.setFrameSize(NSSize(width: 1, height: 1))
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.attach(to: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: BridgeCoordinator) {
        coordinator.detach()
    }

    @MainActor
    final class BridgeCoordinator {
        private let model: WindowModel
        private let coordinator: WindowCoordinator
        private weak var view: NSView?
        private var closeObserver: NSObjectProtocol?

        init(model: WindowModel, coordinator: WindowCoordinator) {
            self.model = model
            self.coordinator = coordinator
        }

        func attach(to view: NSView) {
            self.view = view
            // 视图刚进窗口时 window 还是 nil，等下一轮 run loop 再挂钩。
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.hookWindowIfNeeded() }
            }
        }

        func detach() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
            }
            closeObserver = nil
        }

        private func hookWindowIfNeeded() {
            guard let view, let window = view.window else { return }
            coordinator.register(window: window, for: model)
            guard model.id != coordinator.primary.id else { return }
            // 第二扇窗口不参与系统的窗口恢复：它没有会话可恢复，重开一扇空白窗
            // 只会让人以为自己丢了东西。按窗口记账是 beta 的事。
            window.isRestorable = false
            // 系统把新窗口摆在前一扇的正上方：两扇窗完全重合，⌘N 看起来像什么都没发生。
            // 挪开一点，让人一眼看见「多了一张桌子」。
            if let source = coordinator.window(for: coordinator.primary.id) {
                window.setFrameTopLeftPoint(
                    NSPoint(x: source.frame.minX + 32, y: source.frame.maxY - 32)
                )
            }
            guard closeObserver == nil else { return }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.coordinator.windowDidClose(self.model)
                }
            }
        }
    }
}

/// 把 `openWindow` 捞出来：菜单命令在窗口之外，读不到场景环境。
struct OpenWindowBridge: View {
    @Environment(\.openWindow) private var openWindow
    let coordinator: WindowCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { coordinator.openWindowAction = openWindow }
    }
}
