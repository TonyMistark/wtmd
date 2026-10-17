import Foundation
import Testing
@testable import wtmd

// MARK: - 字面量

private func scan(_ text: String, _ query: String, _ options: FindOptions = []) -> FindScan {
    FindEngine.scan(text as NSString, query: query, options: options)
}

@Test func literalScanFindsEveryOccurrence() {
    let result = scan("the cat sat on the mat", "at")
    #expect(result.error == nil)
    #expect(result.matches.map(\.location) == [5, 9, 20])
    #expect(result.matches.allSatisfy { $0.length == 2 })
}

/// 默认不区分大小写：搜索是为了找到，不是为了较真大小写。
@Test func caseIsIgnoredUnlessAskedFor() {
    #expect(scan("Alpha alpha ALPHA", "alpha").matches.count == 3)
    #expect(scan("Alpha alpha ALPHA", "alpha", .caseSensitive).matches.count == 1)
}

@Test func wholeWordRejectsPartialWords() {
    let text = "cat concat cats cat."
    let result = scan(text, "cat", .wholeWord)
    #expect(result.matches.map(\.location) == [0, 16])
}

/// 汉字在 Unicode 里算字母，所以「全词」在中文里等于「前后是标点或空白」。
/// 不发明分词规则——这是各类编辑器的一致做法，也比猜边界更可预期。
@Test func wholeWordInChineseMeansPunctuationBounded() {
    #expect(scan("《文档》", "文档", .wholeWord).matches.count == 1)
    #expect(scan("中文文档库", "文档", .wholeWord).matches.isEmpty)
}

@Test func emptyQueryFindsNothing() {
    #expect(scan("anything", "").matches.isEmpty)
    #expect(scan("", "anything").matches.isEmpty)
}

/// 匹配不重叠：`aa` 在 `aaaa` 里是两处，不是三处。
@Test func matchesDoNotOverlap() {
    #expect(scan("aaaa", "aa").matches.map(\.location) == [0, 2])
}

@Test func runawayQueriesAreCapped() {
    let text = String(repeating: "a", count: FindEngine.matchLimit + 500)
    let result = scan(text, "a")
    #expect(result.matches.count == FindEngine.matchLimit)
}

// MARK: - 正则

@Test func regexReportsAnInvalidPatternInsteadOfCrashing() {
    let result = scan("anything", "[", .regex)
    #expect(result.matches.isEmpty)
    #expect(result.error != nil)
}

/// `^` 之类的零长度匹配要跳过：否则「1 / 1」永远停在同一处，上一处/下一处原地打转。
@Test func zeroLengthRegexMatchesAreSkipped() {
    #expect(scan("one\ntwo", "^", .regex).matches.isEmpty)
}

@Test func regexHonoursCaseAndWholeWord() {
    #expect(scan("Cat cat", "cat", [.regex]).matches.count == 2)
    #expect(scan("Cat cat", "cat", [.regex, .caseSensitive]).matches.count == 1)
    #expect(scan("cat concat", "cat", [.regex, .wholeWord]).matches.count == 1)
}

// MARK: - 替换

@Test func replacingAllReturnsNilWhenNothingMatches() {
    #expect(FindEngine.replacingAll(in: "abc", query: "zz", options: [], template: "x") == nil)
}

@Test func replacingAllHandlesLengthChanges() {
    let text = "one two three"
    #expect(
        FindEngine.replacingAll(in: text, query: "o", options: [], template: "OO") == "OOne twOO three"
    )
    #expect(
        FindEngine.replacingAll(in: text, query: "e", options: [], template: "") == "on two thr"
    )
}

/// 正则替换要能展开反向引用，否则「把 2026-10-17 改成 10/2026」这类活干不了。
@Test func replacingAllExpandsBackreferences() {
    let text = "2026-10-17"
    let result = FindEngine.replacingAll(
        in: text, query: "(\\d+)-(\\d+)", options: [.regex], template: "$2/$1"
    )
    #expect(result == "10/2026-17")
}

@Test func replacingAllRespectsWholeWord() {
    let text = "cat concat"
    #expect(
        FindEngine.replacingAll(in: text, query: "cat", options: [.wholeWord], template: "dog")
            == "dog concat"
    )
}
