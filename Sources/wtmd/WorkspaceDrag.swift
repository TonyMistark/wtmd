import Foundation
import UniformTypeIdentifiers

/// 树内拖拽的载荷。
///
/// 用自己的 UTI 而不是 `public.file-url` 是有意的：拖拽移动会真的改磁盘，
/// 从访达误拖一堆文件进来，不该是「⌘Z 一下就能回去」的事。凡不是树里
/// 抓起来的那一行，一概不接。
///
/// 载荷就是一行 UTF-8 路径——比序列化整个 URL（含书签、相对基准）小得多，
/// 而且在同一台机器、同一个进程内，路径本来就是最直接的身份。
enum WorkspaceDrag {
    /// 声明在 `make-app.sh` 的 Info.plist 里（`UTExportedTypeDeclarations`）。
    static let type = UTType(exportedAs: "cn.wtmd.workspace-row")

    static func payload(for url: URL) -> Data {
        Data(url.path.utf8)
    }

    static func url(fromPayload data: Data) -> URL? {
        guard let path = String(data: data, encoding: .utf8), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func provider(for url: URL) -> NSItemProvider {
        NSItemProvider(item: payload(for: url) as NSData, typeIdentifier: type.identifier)
    }
}
