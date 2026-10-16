import SwiftUI

/// Zero-dependency fuzzy matching for the command palette.
///
/// The goal is that three or four keystrokes put the wanted command **first**.
/// Hence contiguous hits are weighted far above scattered ones — `pdf` should
/// beat a title that merely contains p, d and f in that order.
enum CommandSearch {
    /// One hit: higher `score` ranks first, `titleHits` are the character
    /// offsets to highlight in the result row.
    struct Result: Identifiable {
        let command: AppCommand
        let score: Int
        let titleHits: [Int]

        var id: String { command.id }
    }

    /// A title hit always outranks a keyword-only hit, so a keyword match is
    /// scaled down rather than scored on its own scale.
    private static let keywordPenalty = 0.5

    static func filter(_ query: String, in commands: [AppCommand]) -> [Result] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty query lists everything in definition order: the palette
            // should be browsable, not require knowing command names by heart.
            return commands.map { Result(command: $0, score: 0, titleHits: []) }
        }

        let needle = Array(trimmed)
        let scored: [(index: Int, result: Result)] = commands.enumerated().compactMap { index, command in
            if let title = bestMatch(needle, in: command.title) {
                return (index, Result(command: command, score: title.score, titleHits: title.hits))
            }
            // Fall back to the English aliases, without highlight offsets — we
            // would have nothing sensible to highlight in the title.
            guard let keywordScore = command.keywords
                .compactMap({ bestMatch(needle, in: $0)?.score })
                .max()
            else { return nil }
            return (index, Result(
                command: command,
                score: Int(Double(keywordScore) * keywordPenalty),
                titleHits: []
            ))
        }

        // `sort` is not stable, so ties fall back to definition order explicitly.
        return scored
            .sorted { lhs, rhs in
                lhs.result.score == rhs.result.score
                    ? lhs.index < rhs.index
                    : lhs.result.score > rhs.result.score
            }
            .map(\.result)
    }

    /// A subsequence match: where it hit, and how well.
    struct Match: Equatable {
        let hits: [Int]
        let score: Int
    }

    /// Subsequence match plus scoring. Returns nil when `needle` is not a
    /// subsequence of `haystack`; otherwise the hit offsets and a score.
    ///
    /// Both sides are folded to lower case here rather than at the call sites,
    /// so a caller can never get a silently case-sensitive match.
    static func bestMatch(_ needle: [Character], in haystack: String) -> Match? {
        let needle = Array(String(needle).lowercased())
        guard !needle.isEmpty else { return Match(hits: [], score: 0) }
        let lowered = haystack.lowercased()
        let chars = Array(lowered)

        var hits: [Int] = []
        var cursor = 0
        for (index, char) in chars.enumerated() where cursor < needle.count {
            if char == needle[cursor] {
                hits.append(index)
                cursor += 1
            }
        }
        guard cursor == needle.count else { return nil }

        var score = needle.count * 2

        // Contiguous runs are the main signal: a run of length n earns n².
        var runs: [Int] = []
        var runLength = 1
        for index in 1..<hits.count {
            if hits[index] == hits[index - 1] + 1 {
                runLength += 1
            } else {
                runs.append(runLength)
                runLength = 1
            }
        }
        runs.append(runLength)
        for run in runs where run > 1 { score += run * run }

        // Start of title, or start of a word.
        for hit in hits {
            if hit == 0 {
                score += 12
            } else if isWordBoundary(chars[hit - 1]) {
                score += 6
            }
        }

        // The whole needle as one substring is the strongest signal of intent.
        if lowered.contains(String(needle)) { score += 25 }

        return Match(hits: hits, score: score)
    }

    private static func isWordBoundary(_ character: Character) -> Bool {
        character == " " || character == "." || character == "/" || character == "-"
            || character == "·" || character == "（" || character == "("
    }

    /// Lay the results out as display rows.
    ///
    /// An empty query gets section headers so the whole list can be browsed; a
    /// non-empty query stays flat, because headers would break the relevance
    /// ordering that the user is scanning.
    static func rows(for query: String, results: [Result]) -> [PaletteRow] {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return results.map(PaletteRow.command)
        }
        var rows: [PaletteRow] = []
        var current: CommandSection?
        for result in results {
            if result.command.section != current {
                rows.append(.header(result.command.section))
                current = result.command.section
            }
            rows.append(.command(result))
        }
        return rows
    }
}

/// A line in the palette: either a section header or a command.
enum PaletteRow: Identifiable {
    case header(CommandSection)
    case command(CommandSearch.Result)

    var id: String {
        switch self {
        case .header(let section): return "header.\(section.id)"
        case .command(let result): return result.id
        }
    }
}
