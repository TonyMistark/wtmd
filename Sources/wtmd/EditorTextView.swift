import AppKit
import SwiftUI

/// 源码编辑器：NSTextView 封装 + 基于行的语法高亮。
struct EditorTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var cursorLine: Int
    var jump: JumpRequest?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let textView = coordinator.textView

        if textView.string != text, !coordinator.isEditing {
            textView.string = text
            Self.highlight(textView)
            coordinator.rebuildLineStarts()
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        if let jump, jump.id != coordinator.lastJumpID {
            coordinator.lastJumpID = jump.id
            coordinator.jump(toLine: jump.line)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditorTextView
        let scrollView: NSScrollView
        let textView: NSTextView
        var isEditing = false
        var lastJumpID = ""
        private var lineStarts: [Int] = []

        init(_ parent: EditorTextView) {
            self.parent = parent

            let textView = NSTextView()
            textView.isRichText = false
            textView.allowsUndo = true
            textView.usesFindBar = true
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
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            self.scrollView = scrollView

            super.init()
            textView.delegate = self
            EditorTextView.highlight(textView)
            rebuildLineStarts()
        }

        static let font = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
        static let boldFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .semibold)

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            isEditing = true
            parent.text = textView.string
            EditorTextView.highlight(textView)
            rebuildLineStarts()
            isEditing = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            let location = textView.selectedRange().location
            var line = 0
            for (idx, start) in lineStarts.enumerated() {
                if start <= location { line = idx } else { break }
            }
            parent.cursorLine = line
        }

        // MARK: 跳转

        func jump(toLine line: Int) {
            guard line >= 0, line < lineStarts.count else { return }
            let location = lineStarts[line]
            textView.selectedRange = NSRange(location: location, length: 0)
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            textView.window?.makeFirstResponder(textView)
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

    // MARK: - 语法高亮（基于行扫描）

    static func highlight(_ textView: NSTextView) {
        let content = NSString(string: textView.string)
        guard content.length < 400_000 else { return }

        let full = NSRange(location: 0, length: content.length)
        let attributed = NSMutableAttributedString(attributedString: textView.textStorage!)
        attributed.beginEditing()
        attributed.setAttributes(
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
                attributed.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: lineRange)
                attributed.addAttribute(.font, value: Coordinator.font, range: lineRange)
                inFence.toggle()
                lineStart = lineEnd
                if lineStart >= content.length { break }
                continue
            }

            if inFence {
                attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: lineRange)
                lineStart = lineEnd
                if lineStart >= content.length { break }
                continue
            }

            // 标题行
            if trimmed.hasPrefix("#"), let level = headingLevel(trimmed) {
                let size = CGFloat(max(13.5, 13.5 + Double(4 - level) * 1.2))
                let headingFont = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
                attributed.addAttribute(.font, value: headingFont, range: lineRange)
                attributed.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: lineRange)
            }
            // 引用行
            else if trimmed.hasPrefix(">") {
                attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: lineRange)
                if let markerRange = firstMatch(lineNS, pattern: #"^>\s?"#) {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen.withAlphaComponent(0.55), range: markerRange)
                }
            }
            // 普通行：行内标记
            else {
                // 列表标记
                if let m = firstMatch(lineNS, pattern: #"^\s*(?:[-*+]|\d{1,9}[.)])(\s+\[[ xX]\])?\s"#) {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: m)
                } else if let m = firstMatch(lineNS, pattern: #"^\s*(?:[-*+]|\d{1,9}[.)])\s?"#) {
                    attributed.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: m)
                }

                apply(lineNS, to: attributed, base: lineRange.location)
            }

            if lineEnd >= content.length { break }
            lineStart = lineEnd
        }

        attributed.endEditing()
        textView.textStorage?.setAttributedString(attributed)
    }

    private static func apply(_ line: NSString, to attributed: NSMutableAttributedString, base: Int) {
        func add(_ pattern: String, _ attrs: [NSAttributedString.Key: Any]) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return }
            re.enumerateMatches(in: line as String, range: NSRange(location: 0, length: line.length)) { m, _, _ in
                guard let m else { return }
                for (k, v) in attrs {
                    attributed.addAttribute(k, value: v, range: NSRange(location: base + m.range.location, length: m.range.length))
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
}
