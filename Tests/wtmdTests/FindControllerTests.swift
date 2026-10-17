import Foundation
import Testing
@testable import wtmd

private let sample = "alpha beta alpha gamma alpha"

@MainActor
private func opened(_ text: String = sample, query: String = "alpha") -> FindController {
    let find = FindController()
    find.attach(text)
    find.present(focusingReplacement: false)
    find.query = query
    return find
}

@Test @MainActor func presentingStartsAtTheFirstMatch() {
    let find = opened()
    #expect(find.isVisible)
    #expect(find.matches.count == 3)
    #expect(find.currentIndex == 0)
    #expect(find.statusText == "1 / 3")
    #expect(find.currentMatch?.location == 0)
}

@Test @MainActor func nextAndPreviousWrapBothWays() {
    let find = opened()
    find.next()
    #expect(find.currentIndex == 1)
    find.next()
    find.next()
    #expect(find.currentIndex == 0, "走到末尾之后应该绕回开头")

    find.previous()
    #expect(find.currentIndex == 2)
}

/// 查询词一变就回到第一个命中：读者改词是在问「那它在哪儿」，
/// 而不是「从上次的第三处继续」。
@Test @MainActor func changingTheQueryRestartsFromTheFirstHit() {
    let find = opened()
    find.next()
    find.query = "gamma"
    #expect(find.matches.count == 1)
    #expect(find.currentIndex == 0)
}

@Test @MainActor func changingOptionsRescans() {
    let find = opened("Alpha alpha")
    #expect(find.matches.count == 2)
    find.options.insert(.caseSensitive)
    #expect(find.matches.count == 1)
}

/// 文本变化会重算命中，但**不抢光标**——读者正在那儿打字。
/// 查询词变化才会 bump `seekToken`。
@Test @MainActor func typingRescansWithoutMovingTheCaret() {
    let find = opened("alpha beta")
    let tokenAfterOpen = find.seekToken
    find.attach("alpha beta alpha")
    #expect(find.matches.count == 2)
    #expect(find.seekToken == tokenAfterOpen)
}

@Test @MainActor func replaceKeepsLookingAfterTheReplacedText() throws {
    let find = opened()
    let first = try #require(find.currentMatch)
    find.replacement = "ALPHA"
    find.noteReplacement(at: first, newLength: 5)
    find.attach("ALPHA beta alpha gamma alpha")
    // 替换后的文本比原来短不了多少，但默认不区分大小写：`ALPHA` 也算命中，
    // 所以下一个落点是原来第二处（位置 11），而不是原地不动
    #expect(find.currentIndex == 1)
    #expect(find.currentMatch?.location == 11)
}

@Test @MainActor func dismissingClearsEverything() {
    let find = opened()
    find.dismiss()
    #expect(!find.isVisible)
    #expect(find.matches.isEmpty)
    #expect(find.currentMatch == nil)
    #expect(find.statusText.isEmpty)
}

@Test @MainActor func invalidRegexSurfacesInTheStatusText() {
    let find = FindController()
    find.attach(sample)
    find.present(focusingReplacement: false)
    find.options.insert(.regex)
    find.query = "["
    #expect(find.matches.isEmpty)
    #expect(find.currentMatch == nil)
    #expect(find.statusText == "正则表达式无效")
}

@Test @MainActor func emptyQueryShowsNoCount() {
    let find = FindController()
    find.attach(sample)
    find.present(focusingReplacement: false)
    #expect(find.statusText.isEmpty)
}
