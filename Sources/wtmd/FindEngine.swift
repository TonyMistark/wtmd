import Foundation

/// What a find session is looking for.
struct FindOptions: OptionSet, Hashable, Sendable {
    let rawValue: Int

    /// `Aa` on means exact case. Off (the default) is case-insensitive: people
    /// search to find something, not to be exact about its capitalisation.
    static let caseSensitive = FindOptions(rawValue: 1 << 0)
    /// Only hits bounded by non-word characters. Word characters are letters,
    /// digits and `_`.
    static let wholeWord = FindOptions(rawValue: 1 << 1)
    /// Treat the query as an ICU regular expression (`NSRegularExpression`).
    static let regex = FindOptions(rawValue: 1 << 2)
}

/// The outcome of scanning one document.
///
/// `error` is set when the *pattern* is invalid. The bar shows it instead of
/// "no results", which would be a lie — nothing was searched.
struct FindScan: Equatable, Sendable {
    var matches: [NSRange] = []
    var error: String?
}

/// Matching, kept free of UI and of `NSTextView` so it can be tested directly.
///
/// Ranges are UTF-16 offsets into the source text (`NSString`), which is what
/// both `NSTextView` and our highlight layer speak.
enum FindEngine {
    /// Upper bound on hits. A single letter in a book-length document can match
    /// tens of thousands of times; highlighting them all costs more than it
    /// tells the reader, and the count is still honest ("5000+").
    static let matchLimit = 5_000

    static func scan(_ text: NSString, query: String, options: FindOptions) -> FindScan {
        guard !query.isEmpty, text.length > 0 else { return FindScan() }
        if options.contains(.regex) {
            return regexScan(text, query, options)
        }
        return literalScan(text, query, options)
    }

    // MARK: - Literal

    private static func literalScan(
        _ text: NSString,
        _ query: String,
        _ options: FindOptions
    ) -> FindScan {
        let compare: NSString.CompareOptions = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
        let queryLength = (query as NSString).length
        var matches: [NSRange] = []
        var cursor = 0

        while cursor + queryLength <= text.length, matches.count < matchLimit {
            let window = NSRange(location: cursor, length: text.length - cursor)
            let found = text.range(of: query, options: compare, range: window)
            if found.location == NSNotFound { break }

            if options.contains(.wholeWord), !isWholeWord(found, in: text) {
                // Step one character, not past the hit: "cat" rejected inside
                // "concat" may still be a whole word one character later.
                cursor = found.location + 1
                continue
            }

            matches.append(found)
            cursor = found.location + max(found.length, 1)
        }
        return FindScan(matches: matches)
    }

    // MARK: - Regex

    private static func regexScan(
        _ text: NSString,
        _ query: String,
        _ options: FindOptions
    ) -> FindScan {
        guard let regex = makeRegex(query, options) else {
            return FindScan(matches: [], error: t("Invalid regular expression"))
        }
        var matches: [NSRange] = []
        let full = NSRange(location: 0, length: text.length)
        regex.enumerateMatches(in: text as String, options: [], range: full) { result, _, stop in
            guard let result else { return }
            let range = result.range
            // A pattern like `^` matches the empty string. Highlighting nothing
            // would still show "1 / 1" and trap "next" on the same spot forever.
            guard range.length > 0 else { return }
            if options.contains(.wholeWord), !isWholeWord(range, in: text) { return }
            matches.append(range)
            if matches.count >= matchLimit { stop.pointee = true }
        }
        return FindScan(matches: matches)
    }

    private static func makeRegex(_ query: String, _ options: FindOptions) -> NSRegularExpression? {
        let regexOptions: NSRegularExpression.Options = options.contains(.caseSensitive) ? [] : [.caseInsensitive]
        return try? NSRegularExpression(pattern: query, options: regexOptions)
    }

    // MARK: - Replacement

    /// The document with every hit replaced, or `nil` when nothing matched.
    ///
    /// Regex mode expands backreferences (`$1`, `\1`), so a query with capture
    /// groups behaves the way writers expect from other editors.
    static func replacingAll(
        in text: String,
        query: String,
        options: FindOptions,
        template: String
    ) -> String? {
        let source = text as NSString
        let scan = scan(source, query: query, options: options)
        guard !scan.matches.isEmpty else { return nil }

        let output = NSMutableString(string: text)
        if options.contains(.regex), let regex = makeRegex(query, options) {
            var results: [NSTextCheckingResult] = []
            regex.enumerateMatches(
                in: text,
                options: [],
                range: NSRange(location: 0, length: source.length)
            ) { result, _, stop in
                guard let result, result.range.length > 0 else { return }
                if options.contains(.wholeWord), !isWholeWord(result.range, in: source) { return }
                results.append(result)
                if results.count >= matchLimit { stop.pointee = true }
            }
            // Back to front, so earlier ranges stay valid while we edit.
            for result in results.reversed() {
                let piece = regex.replacementString(for: result, in: text, offset: 0, template: template)
                output.replaceCharacters(in: result.range, with: piece)
            }
        } else {
            for range in scan.matches.reversed() {
                output.replaceCharacters(in: range, with: template)
            }
        }
        return output as String
    }

    // MARK: - Word boundaries

    private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        if range.location > 0, isWordUnit(text.character(at: range.location - 1)) { return false }
        let end = NSMaxRange(range)
        if end < text.length, isWordUnit(text.character(at: end)) { return false }
        return true
    }

    /// Letters, digits and `_`. CJK characters count as letters, so inside a run
    /// of Chinese a hit is only "whole" when punctuation or whitespace bounds it.
    /// Inventing a segmentation rule would surprise more than it helps.
    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
