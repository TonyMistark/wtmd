import AppKit
import SwiftUI

/// Tooltip for a toolbar item.
///
/// SwiftUI's `.help` never reaches AppKit inside a toolbar: the item's hosting
/// view keeps `toolTip == nil` (verified against a real `NSToolbar`), so no
/// tooltip appears at all. This anchor walks up to the view the toolbar item
/// owns — identified through the public `NSToolbarItem.view` — and writes the
/// string there, where AppKit's own tooltip machinery picks it up for the whole
/// button, not just the icon.
struct ToolbarTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.text = text
        return anchor
    }

    func updateNSView(_ anchor: Anchor, context: Context) {
        anchor.text = text
        anchor.attach()
        // The item may not own its hosting view yet on the first update; the
        // next turn of the run loop is when the toolbar has wired it up.
        DispatchQueue.main.async { anchor.attach() }
    }

    final class Anchor: NSView {
        var text: String = ""

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        /// 把 toolTip 挂到工具栏项自己的视图上：悬停整块按钮都会命中。
        ///
        /// AppKit 的 tooltip 是逐视图登记的，悬停点往往落在按钮内部的某个子视图上；
        /// 宿主与其整棵子树都写上同一句，才不会出现「图标上有、边上没有」。
        func attach() {
            guard let items = window?.toolbar?.items else { return }
            var ancestor: NSView? = superview
            while let current = ancestor {
                if items.contains(where: { $0.view === current }) {
                    stamp(current)
                    return
                }
                ancestor = current.superview
            }
        }

        private func stamp(_ view: NSView) {
            view.toolTip = text
            for subview in view.subviews { stamp(subview) }
        }
    }
}
