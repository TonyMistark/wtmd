import Foundation

/// 文件操作失败的原因。
///
/// 类型化是为了让界面能就地用一句话说清，而不是把 `NSError` 的英文长句抖给读者。
enum FileOperationError: LocalizedError, Equatable {
    case emptyName
    case nameContainsSeparator
    case hiddenName
    case alreadyExists(String)
    case notFound(String)
    case notADirectory(String)
    case moveIntoItself(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "名字不能为空"
        case .nameContainsSeparator:
            return "名字里不能有「/」或「:」"
        case .hiddenName:
            return "名字不能以「.」开头"
        case .alreadyExists(let name):
            return "「\(name)」已经存在"
        case .notFound(let name):
            return "「\(name)」已经不在了"
        case .notADirectory(let name):
            return "「\(name)」不是一个文件夹"
        case .moveIntoItself(let name):
            return "不能把「\(name)」移到它自己里面"
        case .failed(let reason):
            return reason
        }
    }
}

/// 工作区里的文件操作。
///
/// 写成一组纯函数：磁盘是唯一真相，调用方只拿结果，所以这些规则可以脱离窗口、
/// 脱离 store 单独验证。目录的扇出、编号、扩展名处理都在这里定死，界面只负责
/// 把用户的意图翻译成一次调用。
enum WorkspaceFiles {
    static let documentBaseName = "未命名"
    static let folderBaseName = "新建文件夹"

    /// Creates an empty Markdown file with a name that is free right now.
    ///
    /// 编号而不是覆盖：读者连按两次「新建」，第二篇不能把第一篇吃掉。
    static func createDocument(
        in directory: URL,
        manager: FileManager = .default
    ) throws -> URL {
        let url = uniqueURL(
            in: directory, baseName: documentBaseName, pathExtension: "md", manager: manager
        )
        try Data().write(to: url)
        return url
    }

    static func createFolder(
        in directory: URL,
        manager: FileManager = .default
    ) throws -> URL {
        let url = uniqueURL(in: directory, baseName: folderBaseName, manager: manager)
        try manager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames in place and returns the new URL.
    ///
    /// 只改名字，不换身份：文档的扩展名永远跟着原文件走。让 `note.md` 改成
    /// `note.txt` 在 wtmd 里等于「这篇文档从树里消失了」，那不是改名该有的副作用。
    static func rename(
        _ url: URL,
        to rawName: String,
        manager: FileManager = .default
    ) throws -> URL {
        guard manager.fileExists(atPath: url.path) else {
            throw FileOperationError.notFound(url.lastPathComponent)
        }
        var name = try normalizedName(rawName)
        let isDirectory = WorkspaceScanner.isDirectory(url)
        if !isDirectory {
            let pathExtension = url.pathExtension
            if !pathExtension.isEmpty,
               !name.lowercased().hasSuffix("." + pathExtension.lowercased()) {
                name = (name as NSString).deletingPathExtension + "." + pathExtension
            }
        }

        let directory = url.deletingLastPathComponent()
        let target = directory.appendingPathComponent(name, isDirectory: isDirectory)
        if target.standardizedFileURL.path == url.standardizedFileURL.path { return url }

        // 大小写改名（note.md → Note.md）在大小写不敏感的文件系统上，目标路径
        // 指向的就是源文件自己：先挪到临时名再落到目标名，否则会被判成「已存在」。
        let isCaseOnlyChange =
            url.lastPathComponent.lowercased() == name.lowercased()
            && url.lastPathComponent != name
        if isCaseOnlyChange {
            let temporary = directory.appendingPathComponent(".wtmd-rename-\(UUID().uuidString)")
            do {
                try manager.moveItem(at: url, to: temporary)
                try manager.moveItem(at: temporary, to: target)
            } catch {
                // 中途失败就把原文件放回原名，别把文档留在临时名上
                try? manager.moveItem(at: temporary, to: url)
                throw FileOperationError.failed(error.localizedDescription)
            }
            return target
        }

        if manager.fileExists(atPath: target.path) {
            throw FileOperationError.alreadyExists(name)
        }
        do {
            try manager.moveItem(at: url, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// Moves `source` into `directory` under its current name.
    ///
    /// 移动不改名：名字是读者给这份稿子起的，换个抽屉不该顺手改掉。同名冲突
    /// **报错不覆盖**——拖拽是容易手滑的手势，而手滑不该有删除的后果。
    ///
    /// 落点就是原来的父目录时原样返回：什么都没发生，调用方据此跳过状态迁移。
    static func move(
        _ source: URL,
        into directory: URL,
        manager: FileManager = .default
    ) throws -> URL {
        guard manager.fileExists(atPath: source.path) else {
            throw FileOperationError.notFound(source.lastPathComponent)
        }
        guard WorkspaceScanner.isDirectory(directory) else {
            throw FileOperationError.notADirectory(directory.lastPathComponent)
        }
        let isDirectory = WorkspaceScanner.isDirectory(source)
        let target = directory.appendingPathComponent(source.lastPathComponent, isDirectory: isDirectory)

        if PathKey.isSame(target, source) {
            return source
        }
        // 把文件夹拖进它自己（或自己的子孙）会把整棵子树从树上摘下来：先拒。
        if PathKey.isDescendantOrSelf(directory, of: source) {
            throw FileOperationError.moveIntoItself(source.lastPathComponent)
        }
        if manager.fileExists(atPath: target.path) {
            throw FileOperationError.alreadyExists(target.lastPathComponent)
        }
        do {
            try manager.moveItem(at: source, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// Moves to the Trash rather than unlinking: 误删还能捞回来。
    ///
    /// `moveToTrash` is injectable because a test must not push files into the
    /// user's real Trash.
    static func trash(
        _ url: URL,
        manager: FileManager = .default,
        moveToTrash: (URL) throws -> Void = defaultMoveToTrash
    ) throws {
        guard manager.fileExists(atPath: url.path) else {
            throw FileOperationError.notFound(url.lastPathComponent)
        }
        do {
            try moveToTrash(url)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
    }

    static func defaultMoveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// `未命名.md`, `未命名 2.md`, `未命名 3.md`… first name not taken.
    static func uniqueURL(
        in directory: URL,
        baseName: String,
        pathExtension: String = "",
        manager: FileManager = .default
    ) -> URL {
        func candidate(_ index: Int) -> URL {
            let stem = index == 1 ? baseName : "\(baseName) \(index)"
            let name = pathExtension.isEmpty ? stem : "\(stem).\(pathExtension)"
            return directory.appendingPathComponent(name)
        }
        var index = 1
        var url = candidate(index)
        while manager.fileExists(atPath: url.path), index < 10_000 {
            index += 1
            url = candidate(index)
        }
        return url
    }

    /// Trims surrounding whitespace and rejects names that cannot be a file name.
    static func normalizedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileOperationError.emptyName }
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            throw FileOperationError.nameContainsSeparator
        }
        guard !trimmed.hasPrefix(".") else { throw FileOperationError.hiddenName }
        return trimmed
    }
}
