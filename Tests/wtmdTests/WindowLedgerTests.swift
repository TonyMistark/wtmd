import CoreGraphics
import Foundation
import Testing

@testable import wtmd

// MARK: - 账本

private func temporaryDefaults() throws -> (UserDefaults, String) {
    let name = "wtmd.tests.ledger.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    return (defaults, name)
}

/// 关掉再开，桌上摆的还是那几张。
@Test func theLedgerSurvivesARelaunch() throws {
    let (defaults, name) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    let first = UUID()
    let second = UUID()
    let frame = CGRect(x: 120, y: 80, width: 900, height: 700)

    let book = WindowLedger(defaults: defaults)
    book.add(first, frame: frame)
    book.add(second)

    let reread = WindowLedger(defaults: defaults)
    #expect(reread.ids == [first, second])
    #expect(reread.entry(for: first)?.frame?.rect == frame)
    #expect(reread.entry(for: second)?.frame == nil)
}

/// 关窗之后那一条要真的从盘上消失，否则下次启动会多出一扇幽灵窗。
@Test func removingAWindowEndsItsEntry() throws {
    let (defaults, name) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    let kept = UUID()
    let closed = UUID()
    let book = WindowLedger(defaults: defaults)
    book.add(kept)
    book.add(closed)

    book.remove(closed)

    #expect(book.ids == [kept])
    #expect(WindowLedger(defaults: defaults).ids == [kept])
}

/// 「留一手」也要过得了重启：不然那篇无名稿只在同一次运行里能被找回。
@Test func parkingSurvivesARelaunch() throws {
    let (defaults, name) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    let id = UUID()
    let book = WindowLedger(defaults: defaults)
    book.add(id)
    book.setParked(true, for: id)

    #expect(WindowLedger(defaults: defaults).entry(for: id)?.parked == true)

    book.setParked(false, for: id)
    #expect(WindowLedger(defaults: defaults).entry(for: id)?.parked == false)
}

/// 记下的位置还落在屏幕上吗——拔了外接屏之后，坐标会指向一片不存在的区域。
@Test func aFrameMustStillBeOnSomeScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    #expect(WindowLedger.Frame(CGRect(x: 200, y: 100, width: 800, height: 600)).fits(in: [screen]))
    // 整块在屏幕外面
    #expect(!WindowLedger.Frame(CGRect(x: 1600, y: 100, width: 800, height: 600)).fits(in: [screen]))
    // 只擦到一条边：和丢了没区别
    #expect(!WindowLedger.Frame(CGRect(x: 1400, y: 100, width: 800, height: 600)).fits(in: [screen]))
    // 小得不像一扇真窗口：宁可按没记过处理
    #expect(!WindowLedger.Frame(CGRect(x: 200, y: 100, width: 200, height: 120)).fits(in: [screen]))
    // 第二块屏幕上也算数
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    #expect(WindowLedger.Frame(CGRect(x: 1600, y: 100, width: 800, height: 600)).fits(in: [screen, second]))
}

/// 账本坏了就当它不存在：宁可少恢复几扇窗，也别拿半本账去开窗。
@Test func aCorruptLedgerReadsAsEmpty() throws {
    let (defaults, name) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    defaults.set(Data("not a ledger".utf8), forKey: WindowLedger.key)
    let book = WindowLedger(defaults: defaults)

    #expect(book.entries.isEmpty)

    // 还能继续用：坏数据被下一次写入覆盖掉。
    let id = UUID()
    book.add(id)
    #expect(WindowLedger(defaults: defaults).ids == [id])
}

/// 同一个 id 出现两次会让那扇窗开两次、关两次。
@Test func duplicateWindowsCollapseOnRead() throws {
    let (defaults, name) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    let id = UUID()
    let entries = [WindowLedger.Entry(id: id), WindowLedger.Entry(id: id)]
    defaults.set(try JSONEncoder().encode(entries), forKey: WindowLedger.key)

    #expect(WindowLedger(defaults: defaults).ids == [id])
}

// MARK: - 每扇窗一条会话

/// 两扇窗的会话各存一处：谁也不该读到、更不该盖掉别人的「上次打开的文件」。
@Test func everyWindowKeepsItsOwnSessionRecord() throws {
    let (defaults, name) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    let main = Session(defaults: defaults)
    main.setWorkspace(URL(fileURLWithPath: "/tmp/主桌"))
    main.setOpenFile(URL(fileURLWithPath: "/tmp/主桌/a.md"))

    let id = UUID()
    let extra = Session(window: id, defaults: defaults)
    #expect(extra.workspaceURL == nil)
    extra.setWorkspace(URL(fileURLWithPath: "/tmp/副桌"))
    extra.setOpenFile(URL(fileURLWithPath: "/tmp/副桌/b.md"))

    #expect(Session(defaults: defaults).openFileURL?.path == "/tmp/主桌/a.md")
    #expect(Session(window: id, defaults: defaults).openFileURL?.path == "/tmp/副桌/b.md")
    #expect(Session(defaults: defaults).workspaceURL?.path == "/tmp/主桌")
}

/// 关窗即结束：删键，而且封口——之后的 setter 不许把记录写回来。
///
/// 封口是必需的：窗口关闭时 `DocumentStore` 的退出观察者还会记一次位置，不封口
/// 就等于刚删掉又立刻写回一条空记录，下次启动多出一扇幽灵窗。
@Test func endingARecordDeletesItAndSealsIt() throws {
    let (defaults, name) = try temporaryDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    let id = UUID()
    let session = Session(window: id, defaults: defaults)
    session.setWorkspace(URL(fileURLWithPath: "/tmp/副桌"))
    #expect(defaults.data(forKey: Session.key(for: id)) != nil)

    session.endRecord()

    #expect(defaults.data(forKey: Session.key(for: id)) == nil)
    #expect(Session(window: id, defaults: defaults).workspaceURL == nil)

    // 封口之后照样安静
    session.setOpenFile(URL(fileURLWithPath: "/tmp/副桌/b.md"))
    session.record(
        Session.Position(
            selectionLocation: 3, selectionLength: 0, scrollX: 0, scrollY: 0,
            blockIndex: 0, blockOffset: 0, modifiedAt: nil
        ),
        for: URL(fileURLWithPath: "/tmp/副桌/b.md")
    )
    #expect(defaults.data(forKey: Session.key(for: id)) == nil)
}
