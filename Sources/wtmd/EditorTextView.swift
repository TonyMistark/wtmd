import AppKit
import SwiftUI

/// 源码编辑器：NSTextView 封装 + 基于行的语法高亮。
struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorLine: Int
    /// 待插入的图片引用（由 DocumentStore 生成，插入后清空）。
    @Binding var pendingImageInsert: String?
    var jump: JumpRequest?
    /// 图片粘贴落地回调：返回 true 表示已处理。
    var onImagePaste: ((Data) -> Bool)?
    /// 光标行保持垂直居中。
    var typewriterMode: Bool = false
    /// 当前段落之外的内容退成浅灰。
    var focusMode: Bool = false
    /// 跨视图重建的位置账本（`⌘/` 切换会把编辑器整个重建）。
    var positionMemory: PositionMemory?
    /// 位置账本归属的文档代数；换代即作废旧位置。
    var generation: Int = 0
    /// 查找的全部命中（源码区间）。只用来铺高亮，不参与文本。
    var findMatches: [NSRange] = []
    /// 当前那一条命中。
    var findCurrent: NSRange?
    /// 变了就表示「跳到当前命中」——查询词变化或按了下一个/上一个。
    var findSeekToken: Int = 0
    /// 待执行的替换。范围与替换文本由查找侧算好，撤销栈在这里。
    var replaceRequest: ReplaceRequest?
    /// 替换已落地：让 store 把请求清掉。
    ///
    /// 不清的话，下一次视图重建（`⌘/`、窄窗降级）会拿到同一个请求**再执行一遍**——
    /// 那时文本已经变了，区间指向的是别的字。
    var onReplaceApplied: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        coordinator.syncText(text)

        // 重建后回填一次：此时文本已同步、视图即将布局，异步一拍等布局完成
        coordinator.restorePositionIfNeeded()

        if let jump, jump.id != coordinator.lastJumpID {
            coordinator.lastJumpID = jump.id
            coordinator.jump(toLine: jump.line, column: jump.column, length: jump.length)
        }

        if let insert = pendingImageInsert, insert != coordinator.lastInsertedImage {
            coordinator.lastInsertedImage = insert
            DispatchQueue.main.async { [self] in
                pendingImageInsert = nil
            }
            coordinator.insertAtCursor("![\(insert)](\(insert))")
        }

        if coordinator.appliedFocusMode != focusMode {
            coordinator.appliedFocusMode = focusMode
            coordinator.applyFocusFull()
        }

        if coordinator.appliedTypewriterMode != typewriterMode {
            coordinator.appliedTypewriterMode = typewriterMode
            coordinator.clipView.centersCaret = typewriterMode
            if typewriterMode {
                coordinator.recenter(animated: false)
            } else {
                // 收起那半屏留白：否则关掉开关后文档末尾会浮在半空
                coordinator.settleIntoScrollRange()
            }
        }

        // 替换先于高亮：替换会改文本，命中区间要按改动后的内容重新铺
        if let replaceRequest, replaceRequest.id != coordinator.appliedReplaceID {
            coordinator.appliedReplaceID = replaceRequest.id
            coordinator.applyReplace(replaceRequest)
        }

        if coordinator.appliedFindMatches != findMatches
            || coordinator.appliedFindCurrent != findCurrent {
            coordinator.appliedFindMatches = findMatches
            coordinator.appliedFindCurrent = findCurrent
            coordinator.applyFindHighlights()
        }

        if coordinator.appliedFindSeek != findSeekToken {
            coordinator.appliedFindSeek = findSeekToken
            coordinator.seekToCurrentMatch()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextView
        let scrollView: NSScrollView
        let clipView: TypewriterClipView
        let textView: NSTextView
        var isEditing = false
        var lastJumpID = ""
        var lastInsertedImage = ""
        /// 已经生效的开关状态，用来只在真正变化时重刷。
        var appliedFocusMode = false
        var appliedTypewriterMode = false
        /// 当前未被压暗的区间（专注模式）。
        private var focusedRange: NSRange?
        private var lineStarts: [Int] = []
        /// 上次回填过的文档代数。换文档（代数变）要重新回填一次——否则从树里
        /// 点开另一篇，永远落在文首，而那一篇上次停在哪里是有记录的。
        private var restoredGeneration = -1
        /// 本次代数的回填是否已完成。排期之前记下的一切都是「刚建出来的零点」，
        /// 写进账本就等于把刚存的位置立刻抹掉。
        private var positionRestored = false
        /// 回填期间不播放居中动画：建视图的这一拍窗口还没稳定，动画代理会踩空。
        private var isRestoring = false
        /// 已经铺过的查找状态，用来只在真正变化时重铺。
        var appliedFindMatches: [NSRange] = []
        var appliedFindCurrent: NSRange?
        var appliedFindSeek = 0
        var appliedReplaceID = ""

        init(_ parent: EditorTextView) {
            self.parent = parent

            let textView = EditorTextPasteView()
            textView.isRichText = false
            textView.allowsUndo = true
            // 自绘查找条（⌘F）是唯一的查找入口：系统 find bar 会与它抢同一个
            // 快捷键，还各自维护一套高亮，两套 UI 迟早打架。
            textView.usesFindBar = false
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.font = Self.font
            textView.textColor = .labelColor
            textView.backgroundColor = .textBackgroundColor
            textView.insertionPointColor = .labelColor
            textView.drawsBackground = true
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainerInset = NSSize(width: 10, height: 14)
            textView.textContainer?.lineFragmentPadding = 6
            textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            textView.isEditable = true
            textView.isSelectable = true
            self.textView = textView

            let scrollView = NSScrollView()
            // 自绘 clip view：打字机模式要能滚过内容末尾半屏，好让最后一行也能居中
            let clipView = TypewriterClipView()
            clipView.frame = scrollView.contentView.frame
            clipView.drawsBackground = false
            scrollView.contentView = clipView
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            self.clipView = clipView
            self.scrollView = scrollView

            super.init()
            textView.delegate = self
            textView.onPasteInterceptor = { [weak self] in
                self?.handleImagePasteIfNeeded() ?? false
            }
            // 滚轮/滚动条拖动的每一帧都可能是「读者停下的位置」，随手记下
            clipView.onOriginChange = { [weak self] in
                self?.recordPosition()
            }
            EditorTextView.highlight(textView)
            rebuildLineStarts()
        }

        static let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        static let boldFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold)

        // MARK: NSTextViewDelegate

        /// 把外部（绑定值）的文本同步进编辑器。
        ///
        /// **输入法组合期间绝不能做这件事**：拼音的 marked text 在 setMarkedText 时
        /// 就写进了 textStorage，但它**不触发** `textDidChange`（只有提交才触发），
        /// 所以绑定值此时必然落后于编辑器内容。一旦这个函数拿落后的绑定值覆盖整串
        /// 字符，输入法的 marked range 就地失效——候选窗失去锚点（贴到屏幕角落）、
        /// 确认时 commit 找不到替换区间被丢弃，表现为「中文打不进去」，而英文直键
        /// 输入走 insertText 会先触发 textDidChange，永远碰不到这条路径。
        func syncText(_ text: String) {
            guard !isEditing else { return }
            if textView.hasMarkedText() {
                // 忽略组合段后仍与绑定值一致 → 绑定值只是落后（组合不触发
                // textDidChange），必须放过这次更新，否则组合被打断。
                if matchesIgnoringMarkedText(text) { return }
                // 否则是外部真换了文档（切文件/新建）：先结束组合再同步。
                textView.unmarkText()
            }
            guard textView.string != text else { return }
            textView.string = text
            EditorTextView.highlight(textView)
            rebuildLineStarts()
            // `string` 赋值会把光标送到文档末尾。换文档时应该从文首开始——
            // 视图重建（⌘/ 切回来）也走这条路，回填会随后把光标放回原位。
            textView.selectedRange = NSRange(location: 0, length: 0)
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        /// 去掉 marked text 之后，编辑器内容是否就等于给定文本。
        private func matchesIgnoringMarkedText(_ text: String) -> Bool {
            let marked = textView.markedRange()
            guard marked.location != NSNotFound else { return textView.string == text }
            let content = NSMutableString(string: textView.string)
            guard marked.upperBound <= content.length else { return false }
            content.deleteCharacters(in: marked)
            return (content as String) == text
        }

        func textDidChange(_ notification: Notification) {
            isEditing = true
            parent.text = textView.string
            EditorTextView.highlight(textView)
            rebuildLineStarts()
            // 高亮重建了整串属性，压暗层要重新铺一遍
            applyFocusFull()
            recenter()
            isEditing = false
        }

        /// 回车与 Tab 先问写作规则：列表明明还在，回车不该把它断掉。
        ///
        /// 输入法组合期间一律放行——这时的回车是「确认候选」、Tab 是「翻页」，
        /// 抢过来等于中文打不进去（与 `syncText` 里那条限制同源）。
        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let selection = textView.selectedRange()
            let edit: MarkdownEdit?
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                edit = MarkdownEditing.newline(in: textView.string, selection: selection)
            case #selector(NSResponder.insertTab(_:)):
                edit = MarkdownEditing.indent(in: textView.string, selection: selection, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                edit = MarkdownEditing.indent(in: textView.string, selection: selection, outdent: true)
            default:
                return false
            }
            guard let edit else { return false }
            applyEditing(edit)
            return true
        }

        /// 一次 `insertText` 落地：撤销一步，高亮与光标行由 `textDidChange` 接手。
        private func applyEditing(_ edit: MarkdownEdit) {
            // 不打断合并的话，这次缩进会被并进上一步输入里，⌘Z 一次退掉两件事
            textView.breakUndoCoalescing()
            textView.insertText(edit.text, replacementRange: edit.range)
            if let after = edit.selectionAfter {
                textView.setSelectedRange(after)
            }
        }

        /// 光标处插入文本（用于图片引用）。
        func insertAtCursor(_ snippet: String) {
            // 组合中插入会替换 marked range：先结束组合，让拼音先落定
            if textView.hasMarkedText() { textView.unmarkText() }
            let range = textView.selectedRange()
            textView.insertText(snippet, replacementRange: range)
            isEditing = true
            parent.text = textView.string
            EditorTextView.highlight(textView)
            rebuildLineStarts()
            applyFocusFull()
            recenter()
            isEditing = false
        }

        // MARK: 粘贴拦截

        /// 返回 true 表示本次粘贴已完全处理（图片落地 + 插入引用）。
        func handleImagePasteIfNeeded() -> Bool {
            guard let onPaste = parent.onImagePaste else { return false }
            guard let png = ImageAssets.imagePNGData(from: NSPasteboard.general) else {
                return false
            }
            return onPaste(png)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            let location = textView.selectedRange().location
            var line = 0
            for (idx, start) in lineStarts.enumerated() {
                if start <= location { line = idx } else { break }
            }
            parent.cursorLine = line
            // 光标一动，聚焦段落与居中位置都可能变
            applyFocusIncremental()
            recenter()
            recordPosition()
        }

        // MARK: 位置记忆

        /// 重建 / 换文档后把读者原来的选区与滚动位置还回来（每代一次）。
        ///
        /// 排到下一次 runloop：`updateNSView` 触发时滚动视图还没参与布局，
        /// 这时 `clipView.bounds` 是零高度，直接 `scroll(to:)` 会被夹成 0。
        ///
        /// 换文档时 `syncText` 先把光标放到文首，那一拍触发的选区回调会把「文首」
        /// 写进账本，把这一篇记录的位置冲掉——所以回填完成前 `recordPosition`
        /// 一直是哑的，等回填把 `positionRestored` 打开再开始记账。
        func restorePositionIfNeeded() {
            guard restoredGeneration != parent.generation else { return }
            restoredGeneration = parent.generation
            positionRestored = false
            parent.positionMemory?.startSession(generation: parent.generation)
            let snapshot = parent.positionMemory?.editorPosition
            // 只让最新一代的回填落地：连续切两篇时，前一次排下的异步块还在队列里
            let generation = parent.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.restoredGeneration == generation else { return }
                self.applyStoredPosition(snapshot)
            }
        }

        /// 记下当前位置。回填完成之前不记——那会儿记的都是重建后的零点。
        func recordPosition() {
            guard positionRestored else { return }
            parent.positionMemory?.recordEditorPosition(
                PositionMemory.EditorPosition(
                    selection: textView.selectedRange(),
                    scrollOrigin: clipView.bounds.origin
                )
            )
        }

        func applyStoredPosition(_ snapshot: PositionMemory.EditorPosition?) {
            positionRestored = true
            guard let snapshot else { return }

            isRestoring = true
            defer { isRestoring = false }

            let content = NSString(string: textView.string)
            let location = min(max(0, snapshot.selection.location), content.length)
            let length = min(max(0, snapshot.selection.length), content.length - location)
            textView.selectedRange = NSRange(location: location, length: length)

            if parent.typewriterMode {
                // 打字机模式自己会把光标行拉到中部，再回填原始偏移只会打架
                recenter(animated: false)
            } else {
                if let container = textView.textContainer {
                    textView.layoutManager?.ensureLayout(for: container)
                }
                clipView.scroll(to: snapshot.scrollOrigin)
                scrollView.reflectScrolledClipView(clipView)
            }

            // 回到源码视图就该能接着打字。只在焦点不在别的文本控件上时抢，
            // 免得把命令行/查找栏的焦点夺走。
            if let window = textView.window, !(window.firstResponder is NSTextView) {
                window.makeFirstResponder(textView)
            }
        }

        /// 让滚动位置回到当前模式下允许的范围里。
        func settleIntoScrollRange() {
            let clamped = clipView.constrainBoundsRect(clipView.bounds)
            guard clamped.origin != clipView.bounds.origin else { return }
            clipView.scroll(to: clamped.origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        // MARK: 专注模式

        /// 全量重铺压暗层：文本变过（属性重建）或开关刚切换时用。
        func applyFocusFull() {
            guard let layoutManager = textView.layoutManager else { return }
            // 只有真压暗过才需要全量移除：否则每次按键都要对整篇做一次
            // O(文档长度) 的空转，而专注模式常常是关着的
            if focusedRange != nil {
                let content = NSString(string: textView.string)
                layoutManager.removeTemporaryAttribute(
                    .foregroundColor,
                    forCharacterRange: NSRange(location: 0, length: content.length)
                )
                focusedRange = nil
            }

            guard parent.focusMode else { return }
            let content = NSString(string: textView.string)
            let range = FocusParagraph.range(in: content, caret: textView.selectedRange().location)
            dim(NSRange(location: 0, length: range.location), with: layoutManager)
            let tail = NSRange(
                location: range.location + range.length,
                length: max(0, content.length - range.location - range.length)
            )
            dim(tail, with: layoutManager)
            focusedRange = range
        }

        /// 光标在同一篇文本里移动：只需把新段落点亮、把旧段落压暗。
        ///
        /// 全量重铺是 O(文档长度) 的属性操作，按键之间做不起。
        func applyFocusIncremental() {
            guard parent.focusMode else { return }
            guard let layoutManager = textView.layoutManager else { return }
            guard let previous = focusedRange else {
                applyFocusFull()
                return
            }
            let content = NSString(string: textView.string)
            let range = FocusParagraph.range(in: content, caret: textView.selectedRange().location)
            guard range != previous else { return }

            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
            dim(previous, with: layoutManager)
            focusedRange = range
        }

        /// 压暗：只在 layout manager 上盖一层临时属性，**不碰 textStorage**。
        /// 文本内容与语法高亮都不受影响，下一次高亮重建也不会把它带进来。
        private func dim(_ range: NSRange, with layoutManager: NSLayoutManager) {
            guard range.length > 0 else { return }
            layoutManager.addTemporaryAttribute(
                .foregroundColor,
                value: NSColor.tertiaryLabelColor,
                forCharacterRange: range
            )
        }

        // MARK: 查找

        static let matchColor = NSColor.systemYellow.withAlphaComponent(0.30)
        static let currentMatchColor = NSColor.systemOrange.withAlphaComponent(0.55)

        /// 铺全部命中，并让当前那一条更显眼。
        ///
        /// 同样只写 layout manager 的临时属性——`highlight()` 每次按键都重建整串
        /// textStorage 属性，写进去的底色活不过一次编辑。专注模式压的是
        /// `.foregroundColor`，这里用 `.backgroundColor`，两个开关可以同时开。
        func applyFindHighlights() {
            guard let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            layoutManager.removeTemporaryAttribute(
                .backgroundColor,
                forCharacterRange: NSRange(location: 0, length: length)
            )
            for range in parent.findMatches where range.length > 0 && NSMaxRange(range) <= length {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: Self.matchColor,
                    forCharacterRange: range
                )
            }
            if let current = parent.findCurrent, current.length > 0, NSMaxRange(current) <= length {
                layoutManager.addTemporaryAttribute(
                    .backgroundColor,
                    value: Self.currentMatchColor,
                    forCharacterRange: current
                )
            }
        }

        /// 把选区放到当前命中上。查询词一变、或按了下一个/上一个都会走这里。
        func seekToCurrentMatch() {
            guard let target = parent.findCurrent else { return }
            let length = (textView.string as NSString).length
            guard NSMaxRange(target) <= length else { return }
            // 组合中不抢选区：候选窗会失去锚点，中文输入被打断
            guard !textView.hasMarkedText() else { return }
            textView.setSelectedRange(target)
            textView.scrollRangeToVisible(target)
        }

        /// 执行一次替换。**撤销栈在 `NSTextView` 上**，所以替换必须从这里走，
        /// 不能在 store 里改字符串——那样 ⌘Z 退不回去。
        ///
        /// `shouldChangeText` 与 `didChangeText` 必须成对：一次配对记一步撤销，
        /// 全部替换因此也是「一步」而不是几百步。
        func applyReplace(_ request: ReplaceRequest) {
            let length = (textView.string as NSString).length
            guard NSMaxRange(request.range) <= length else { return }
            if textView.hasMarkedText() { textView.unmarkText() }
            guard textView.shouldChangeText(in: request.range, replacementString: request.replacement) else {
                return
            }
            textView.textStorage?.replaceCharacters(in: request.range, with: request.replacement)
            textView.didChangeText()

            let newLength = (textView.string as NSString).length
            let caret = min(max(0, request.selectionAfter.location), newLength)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.scrollRangeToVisible(NSRange(location: caret, length: 0))

            // 排到下一拍再清：正在 `updateNSView` 里改 store 会触发
            // "Publishing changes from within view updates" 警告。
            let consumed = parent.onReplaceApplied
            DispatchQueue.main.async { consumed?() }
        }

        // MARK: 打字机模式

        /// 让光标所在行停在视口正中。
        ///
        /// 只对光标那一行做布局（`ensureLayout(forCharacterRange:)`）——整篇
        /// `ensureLayout` 在长文档上每次按键都做不起。
        func recenter(animated: Bool = true) {
            guard parent.typewriterMode else { return }
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else { return }

            let content = NSString(string: textView.string)
            let caret = min(max(0, textView.selectedRange().location), content.length)
            let lineRange = content.lineRange(for: NSRange(location: caret, length: 0))
            layoutManager.ensureLayout(forCharacterRange: lineRange)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height

            let viewport = clipView.bounds.height
            let target = TypewriterGeometry.centeredOffset(
                caretMidY: rect.midY,
                viewportHeight: viewport,
                // 内容高度加上 clip view 让出来的那半屏，末尾几行才居得中
                contentHeight: textView.frame.height + viewport / 2
            )
            guard abs(clipView.bounds.origin.y - target) > 0.5 else { return }

            // 只有真正在屏幕上滚动的视图才做动画：离屏/未显示的窗口上跑动画代理，
            // 会在窗口先一步销毁时留下悬空的图层引用（AppKit 下一帧踩空）。
            let canAnimate = animated
                && !isRestoring
                && clipView.window?.isVisible == true
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

            if canAnimate {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.08
                    context.allowsImplicitAnimation = true
                    clipView.animator().setBoundsOrigin(
                        NSPoint(x: clipView.bounds.origin.x, y: target)
                    )
                }
            } else {
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: target))
            }
            scrollView.reflectScrolledClipView(clipView)
        }

        // MARK: 跳转

        func jump(toLine line: Int, column: Int = 0, length: Int = 0) {
            guard line >= 0, line < lineStarts.count else { return }
            let content = NSString(string: textView.string)
            let start = lineStarts[line]
            // 行尾不含换行符：`lineStarts[line + 1]` 指向下一行的第一个字符
            let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : content.length
            let lineLength = max(0, end - start)
            let targetColumn = min(max(0, column), lineLength)
            let targetLength = min(max(0, length), lineLength - targetColumn)
            let target = NSRange(location: start + targetColumn, length: targetLength)

            textView.setSelectedRange(target)
            if parent.typewriterMode {
                recenter()
            } else {
                reveal(target)
            }
            textView.window?.makeFirstResponder(textView)
        }

        /// 让目标停在大约三分之一处，而不是贴着视口边缘。
        ///
        /// `scrollRangeToVisible` 只保证「看得见」，命中落到底部时上半句在屏幕外，
        /// 读者还得自己往上滚一格才知道这句话在说什么。
        private func reveal(_ range: NSRange) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer
            else {
                textView.scrollRangeToVisible(range)
                return
            }
            layoutManager.ensureLayout(forCharacterRange: range)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            let target = max(0, rect.minY - clipView.bounds.height / 3)
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clipView)
        }

        func rebuildLineStarts() {
            let content = NSString(string: textView.string)
            var starts: [Int] = []
            var idx = 0
            starts.append(0)
            while idx < content.length {
                var i = idx
                while i < content.length, content.character(at: i) != unichar(10) { i += 1 }
                if i >= content.length { break }
                starts.append(i + 1)
                idx = i + 1
            }
            lineStarts = starts
        }
    }

    // MARK: - 打字机模式的滚动边界

    /// 打字机模式允许滚过内容末尾半屏。
    ///
    /// 不这么做，文档最后一行永远只能停在屏幕底部——而那正是写作者待得最久的地方。
    /// 注意夹取要用 `proposedBounds`：`super` 的结果已经被夹到内容末尾，拿它再夹一次
    /// 等于什么也没放开。
    final class TypewriterClipView: NSClipView {
        var centersCaret = false
        /// 滚动发生的回调：位置记忆靠它随时记下「读者看到的顶部」。
        var onOriginChange: (() -> Void)?

        override func setBoundsOrigin(_ newOrigin: NSPoint) {
            super.setBoundsOrigin(newOrigin)
            onOriginChange?()
        }

        override func scroll(to newOrigin: NSPoint) {
            super.scroll(to: newOrigin)
            onOriginChange?()
        }

        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            guard centersCaret, let documentView else { return rect }
            let furthest = max(0, documentView.frame.height + rect.height / 2 - rect.height)
            rect.origin.y = min(max(0, proposedBounds.origin.y), furthest)
            return rect
        }
    }

    // MARK: - 粘贴拦截子类

    /// 覆写 paste：粘贴板有图片数据时交给落地管线，否则走系统默认。
    final class EditorTextPasteView: NSTextView {
        var onPasteInterceptor: (() -> Bool)?

        override func paste(_ sender: Any?) {
            if onPasteInterceptor?() == true { return }
            super.paste(sender)
        }
    }

    // MARK: - 语法高亮（基于行扫描）

    /// 语法高亮：只改属性，**不替换字符**。
    ///
    /// 这里曾经把整串属性构建到一份副本上，再用 `NSTextStorage.setAttributedString`
    /// 发布。那是「替换整个字符区间」，TextKit 会把落在被替换区间内的光标映射到替换
    /// 区间的**末尾**——也就是文档末尾。于是在段落中间（尤其是第一行）敲一个键，光标
    /// 就瞬移到文末；打字机模式再把它居中，整篇文档就滚到底。
    ///
    /// 属性编辑不改变字符长度，光标原地不动，顺带省掉一次整串字符替换的布局失效。
    static func highlight(_ textView: NSTextView) {
        let content = NSString(string: textView.string)
        guard content.length < 400_000 else { return }
        guard let storage = textView.textStorage else { return }

        let full = NSRange(location: 0, length: content.length)
        storage.beginEditing()
        storage.setAttributes(
            [.font: Coordinator.font, .foregroundColor: NSColor.labelColor],
            range: full
        )

        var inFence = false
        var lineStart = 0
        while lineStart <= content.length {
            var lineEnd = lineStart
            var contentsEnd = lineStart
            content.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let line = content.substring(with: lineRange)
            let lineNS = line as NSString

            if lineRange.length == 0 && lineStart >= content.length { break }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFenceLine = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")

            if isFenceLine {
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: lineRange)
                storage.addAttribute(.font, value: Coordinator.font, range: lineRange)
                inFence.toggle()
                lineStart = lineEnd
                if lineStart >= content.length { break }
                continue
            }

            if inFence {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
                lineStart = lineEnd
                if lineStart >= content.length { break }
                continue
            }

            // 标题行
            if trimmed.hasPrefix("#"), let level = headingLevel(trimmed) {
                let size = CGFloat(max(13.5, 13.5 + Double(4 - level) * 1.2))
                let headingFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
                storage.addAttribute(.font, value: headingFont, range: lineRange)
                storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: lineRange)
            }
            // 引用行
            else if trimmed.hasPrefix(">") {
                storage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: lineRange)
                if let markerRange = firstMatch(lineNS, pattern: #"^>\s?"#) {
                    // `firstMatch` 给的是行内偏移，染色的 range 要用绝对位置：
                    // 少了这个 base，只有文档第一行能染对，其余行都在染别处。
                    storage.addAttribute(
                        .foregroundColor,
                        value: NSColor.systemGreen.withAlphaComponent(0.55),
                        range: offset(markerRange, by: lineRange.location)
                    )
                }
            }
            // 普通行：行内标记
            else {
                // 列表标记
                if let m = firstMatch(lineNS, pattern: #"^\s*(?:[-*+]|\d{1,9}[.)])(\s+\[[ xX]\])?\s"#) {
                    storage.addAttribute(
                        .foregroundColor,
                        value: NSColor.systemOrange,
                        range: offset(m, by: lineRange.location)
                    )
                } else if let m = firstMatch(lineNS, pattern: #"^\s*(?:[-*+]|\d{1,9}[.)])\s?"#) {
                    storage.addAttribute(
                        .foregroundColor,
                        value: NSColor.systemOrange,
                        range: offset(m, by: lineRange.location)
                    )
                }

                apply(lineNS, to: storage, base: lineRange.location)
            }

            if lineEnd >= content.length { break }
            lineStart = lineEnd
        }

        storage.endEditing()
    }

    private static func apply(_ line: NSString, to storage: NSMutableAttributedString, base: Int) {
        func add(_ pattern: String, _ attrs: [NSAttributedString.Key: Any]) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            re.enumerateMatches(in: line as String, range: NSRange(location: 0, length: line.length)) { m, _, _ in
                guard let m else { return }
                for (k, v) in attrs {
                    storage.addAttribute(k, value: v, range: NSRange(location: base + m.range.location, length: m.range.length))
                }
            }
        }
        add(#"`[^`\n]+`"#, [
            .foregroundColor: NSColor.systemTeal,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
        ])
        add(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, [.font: Coordinator.boldFont])
        add(#"\*[^*\n]+\*|(?<![\w_])_[^_\n]+_(?![\w_])"#, [.obliqueness: 0.18])
        add(#"~~[^~\n]+~~"#, [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        add(#"\[[^\]\n]*\]\([^)\n]*\)"#, [.foregroundColor: NSColor.linkColor])
        add(#"!\[[^\]\n]*\]\([^)\n]*\)"#, [.foregroundColor: NSColor.systemBrown])
        add(#"(?<![\w'\"])(https?://[^\s<>)\"']+)"#, [.foregroundColor: NSColor.linkColor])
    }

    private static func headingLevel(_ line: String) -> Int? {
        var n = 0
        for ch in line {
            if ch == "#" { n += 1 } else { break }
        }
        guard (1...6).contains(n) else { return nil }
        let rest = line.dropFirst(n)
        return rest.isEmpty || rest.first == " " ? n : nil
    }

    private static func firstMatch(_ line: NSString, pattern: String) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        return re.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))?.range
    }

    /// 行内偏移换成文档内偏移。
    private static func offset(_ range: NSRange, by base: Int) -> NSRange {
        NSRange(location: base + range.location, length: range.length)
    }
}
