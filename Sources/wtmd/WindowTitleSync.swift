import AppKit
import Combine
import Foundation

/// Keeps an `NSWindow`'s title in step with the document that window shows.
///
/// `.navigationTitle(store.windowTitle)` is supposed to drive the window title,
/// and it does — until a window of the same scene is closed and a new one is
/// created (#287). The recreated window inherits the cached title of the dead
/// window and SwiftUI stops pushing later changes to `NSWindow.title`, so the
/// content follows the store while the title bar stays on the previous file.
/// Writing the title through AppKit directly is the only path that cannot be
/// cached: the value always comes from the store that actually renders.
@MainActor
final class WindowTitleSync {
    /// Readable so the view bridge can tell whether this sync still anchors
    /// the window it is about to hook — one bridge can see several NSWindows
    /// over its life (fullscreen swaps, scene recreation).
    private(set) weak var window: NSWindow?
    private let store: DocumentStore
    private var cancellable: AnyCancellable?
    private var keyObserver: NSObjectProtocol?

    /// The title depends on three published inputs: which file is open (the
    /// name), and `text` vs `savedSnapshot` (the dirty dot). `savedSnapshot`
    /// changes without `text` when a save lands, so it is observed on its own.
    init(window: NSWindow, store: DocumentStore) {
        self.window = window
        self.store = store
    }

    deinit {
        cancellable?.cancel()
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
    }

    /// Start observing and apply the current title right away — the window may
    /// have been created with a stale cached title that SwiftUI will not fix.
    /// Re-applying whenever the window becomes key guards against SwiftUI
    /// re-writing its cached value on activation events.
    func start() {
        applyCurrent()
        cancellable = Publishers.CombineLatest3(
            store.$text, store.$fileURL, store.$savedSnapshot
        )
        .sink { [weak self] value in
            MainActor.assumeIsolated {
                // Compute from the emitted tuple, not from the store: `@Published`
                // fires on willSet, so the store still holds the previous value
                // while the sink runs — reading it here lags one change behind.
                let (text, fileURL, snapshot) = value
                self?.apply(
                    DocumentStore.windowTitle(text: text, fileURL: fileURL, savedSnapshot: snapshot)
                )
            }
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyCurrent()
            }
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        keyObserver = nil
    }

    private func applyCurrent() {
        apply(store.windowTitle)
    }

    private func apply(_ title: String) {
        guard let window else { return }
        if window.title != title {
            window.title = title
        }
    }
}
