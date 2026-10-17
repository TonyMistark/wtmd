import CoreGraphics
import Foundation

/// Remembers where the reader was, across the view rebuilds that `⌘/` causes.
///
/// `ContentView` builds the editor and the preview in two different branches of a
/// `switch`, so toggling the mode destroys one and constructs the other. Without a
/// notebook that lives outside the views, "back" always means "back to the top" —
/// the single biggest source of friction reported against the dual-view design
/// (see docs/WYSIWYG_EVAL.md).
///
/// Two different kinds of position, because the two views measure position
/// differently:
///
/// - The preview is a web page that gets reloaded from scratch, so a pixel offset
///   (`scrollY`) would be replayed onto a layout that may have shifted. It records
///   a **block index plus the block's offset from the viewport top**, which stays
///   meaningful as long as the block structure does (`#wtmd-content` children ==
///   top-level blocks, an invariant the renderer already keeps).
/// - The editor survives with its text intact but not its selection, so it records
///   the plain `selectedRange` and the clip view's origin.
///
/// Deliberately not actor-isolated: both coordinators already run on the main
/// thread, and pinning this type to `@MainActor` would only force the AppKit
/// delegate callbacks into async hops for a handful of scalar reads and writes.
final class PositionMemory {
    struct EditorPosition: Equatable {
        var selection: NSRange
        var scrollOrigin: CGPoint
    }

    struct PreviewAnchor: Equatable {
        /// Index into `#wtmd-content`'s children (== top-level block index).
        var blockIndex: Int
        /// Distance from the block's top edge to the viewport's top edge.
        /// Positive means the block starts above the viewport, which is the normal
        /// case once the reader has scrolled into the middle of a long block.
        var offset: CGFloat
    }

    private(set) var generation = -1
    private(set) var editorPosition: EditorPosition?
    private(set) var previewAnchor: PreviewAnchor?

    /// Begins (or continues) a session for one document.
    ///
    /// A different generation means a different document, and positions recorded
    /// for the previous one must never be replayed onto the new one: the block
    /// index there points at unrelated content, so the reader would land in a
    /// random place. This is the guard that makes "open another file" behave.
    func startSession(generation: Int) {
        guard generation != self.generation else { return }
        self.generation = generation
        editorPosition = nil
        previewAnchor = nil
    }

    func recordEditorPosition(_ position: EditorPosition) {
        editorPosition = position
    }

    func recordPreviewAnchor(_ anchor: PreviewAnchor) {
        previewAnchor = anchor
    }

    func clear() {
        editorPosition = nil
        previewAnchor = nil
    }
}
