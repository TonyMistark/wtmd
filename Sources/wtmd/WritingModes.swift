import AppKit
import Foundation

/// 心流里的两个开关：光标停在屏幕中部（打字机），当前段落之外退成浅灰（专注）。
///
/// Persisted in UserDefaults; the store is injectable so tests never touch the
/// user's real preferences.
@MainActor
final class WritingSettings: ObservableObject {
    private enum Key {
        static let typewriter = "wtmd.typewriterMode"
        static let focus = "wtmd.focusMode"
        static let dailyGoal = "wtmd.dailyCharacterGoal"
    }

    private let defaults: UserDefaults

    @Published var typewriter: Bool {
        didSet { defaults.set(typewriter, forKey: Key.typewriter) }
    }

    @Published var focusMode: Bool {
        didSet { defaults.set(focusMode, forKey: Key.focus) }
    }

    /// 每日字数目标。**0 表示不设**——状态栏里那条进度只在设了之后才出现。
    @Published var dailyGoal: Int {
        didSet { defaults.set(dailyGoal, forKey: Key.dailyGoal) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        typewriter = defaults.bool(forKey: Key.typewriter)
        focusMode = defaults.bool(forKey: Key.focus)
        dailyGoal = max(0, defaults.integer(forKey: Key.dailyGoal))
    }
}

// MARK: - 当前段落

/// 源码视图里「光标所在的那一段」。
///
/// A paragraph is a run of consecutive non-blank lines; blank lines separate
/// them. This is Markdown's own notion of a paragraph — no need to reuse the
/// rendering-side block split, whose blocks are HTML and carry no source ranges.
enum FocusParagraph {
    /// A line plus where it ends *including* its terminator.
    private struct Line {
        let content: NSRange
        let end: Int
    }

    /// The paragraph containing `caret`.
    ///
    /// A caret on a blank line is folded into the **preceding** paragraph.
    /// Otherwise, hitting return twice to start a new paragraph would blank out
    /// the whole document for that instant — a violent flicker right where the
    /// writer is looking.
    static func range(in text: NSString, caret: Int) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }

        let lines = lineRanges(in: text)
        guard !lines.isEmpty else { return NSRange(location: 0, length: length) }
        let index = lineIndex(forCaret: caret, in: lines, length: length)

        if !isBlank(text, lines[index].content) {
            return run(around: index, blank: false, lines: lines, text: text)
        }
        if let previous = (0..<index).last(where: { !isBlank(text, lines[$0].content) }) {
            let start = lines[previous].content.location
            let end = lines[index].end
            return NSRange(location: start, length: max(0, end - start))
        }
        // 文档开头就是空行：没有可归属的段落，就点亮这片空行本身
        return run(around: index, blank: true, lines: lines, text: text)
    }

    /// Line ranges, terminators excluded from `content` but included in `end`.
    ///
    /// `getLineStart` treats a newline character as belonging to the line it
    /// terminates, which is exactly how a caret sitting on one should behave.
    private static func lineRanges(in text: NSString) -> [Line] {
        let length = text.length
        var lines: [Line] = []
        var start = 0
        while start <= length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(
                &lineStart,
                end: &lineEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: start, length: 0)
            )
            lines.append(Line(content: NSRange(location: lineStart, length: contentsEnd - lineStart), end: lineEnd))
            // 最后一行（没有结尾换行）之后 getLineStart 仍会返回一个空行，
            // 它让「光标在文末」落在最后一段里，语义是对的，留着无妨。
            if lineEnd <= start { break }
            start = lineEnd
        }
        return lines
    }

    private static func lineIndex(forCaret caret: Int, in lines: [Line], length: Int) -> Int {
        let clamped = min(max(0, caret), length)
        for (index, line) in lines.enumerated() {
            let end = line.content.location + line.content.length
            if clamped >= line.content.location, clamped <= end { return index }
        }
        return max(0, lines.count - 1)
    }

    private static func isBlank(_ text: NSString, _ range: NSRange) -> Bool {
        guard range.length > 0 else { return true }
        return text.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func run(around index: Int, blank: Bool, lines: [Line], text: NSString) -> NSRange {
        var lower = index
        while lower > 0, isBlank(text, lines[lower - 1].content) == blank { lower -= 1 }
        var upper = index
        while upper + 1 < lines.count, isBlank(text, lines[upper + 1].content) == blank { upper += 1 }

        let start = lines[lower].content.location
        // A non-blank paragraph stops before its trailing newline (that is the
        // separator); a blank run takes its terminators with it.
        let end = blank
            ? lines[upper].end
            : lines[upper].content.location + lines[upper].content.length
        return NSRange(location: start, length: max(0, end - start))
    }
}

// MARK: - 居中偏移

enum TypewriterGeometry {
    /// Scroll offset that puts a caret line at the middle of the viewport.
    ///
    /// `contentHeight` is the **scrollable** height, so a caller in typewriter
    /// mode passes the content plus the half-screen of padding that makes the
    /// last line of a document centerable at all.
    static func centeredOffset(
        caretMidY: CGFloat,
        viewportHeight: CGFloat,
        contentHeight: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let target = caretMidY - viewportHeight / 2
        let furthest = max(0, contentHeight - viewportHeight)
        return min(max(0, target), furthest)
    }
}
