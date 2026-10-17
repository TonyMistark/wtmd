import Foundation

/// 最小 ZIP 写入器：只支持 stored（不压缩）条目。
///
/// DOCX 是一个 ZIP 容器，而本项目坚持零第三方依赖——这里手写记录结构。
/// XML 内容本身只有几十 KB，省掉 deflate 换来的是没有压缩实现的不确定性；
/// Word / Pages / LibreOffice 都能正常打开 stored 条目。
///
/// 时间戳固定为 2026-01-01，同一个文档导出的字节完全一致（可复现）。
struct ZipWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var output = Data()
    private var entries: [Entry] = []

    mutating func add(_ name: String, _ data: Data) {
        let nameBytes = Array(name.utf8)
        let offset = UInt32(output.count)
        let crc = CRC32.checksum(data)

        output.appendLittleEndian(UInt32(0x0403_4B50))   // local file header
        output.appendLittleEndian(UInt16(20))            // version needed
        output.appendLittleEndian(UInt16(0x0800))        // UTF-8 文件名
        output.appendLittleEndian(UInt16(0))             // method: stored
        output.appendLittleEndian(UInt16(0))             // time
        output.appendLittleEndian(UInt16(0x5C21))        // date: 固定的 2026-01-01
        output.appendLittleEndian(crc)
        output.appendLittleEndian(UInt32(data.count))    // compressed size
        output.appendLittleEndian(UInt32(data.count))    // uncompressed size
        output.appendLittleEndian(UInt16(nameBytes.count))
        output.appendLittleEndian(UInt16(0))             // extra length
        output.append(contentsOf: nameBytes)
        output.append(data)

        entries.append(Entry(name: nameBytes, crc: crc, size: UInt32(data.count), offset: offset))
    }

    mutating func add(_ name: String, _ xml: String) {
        add(name, Data(xml.utf8))
    }

    /// 中央目录 + EOCD。
    func finish() -> Data {
        var archive = output
        let directoryOffset = UInt32(archive.count)

        for entry in entries {
            archive.appendLittleEndian(UInt32(0x0201_4B50))  // central directory header
            archive.appendLittleEndian(UInt16(20))           // version made by
            archive.appendLittleEndian(UInt16(20))           // version needed
            archive.appendLittleEndian(UInt16(0x0800))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0))
            archive.appendLittleEndian(UInt16(0x5C21))
            archive.appendLittleEndian(entry.crc)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(entry.size)
            archive.appendLittleEndian(UInt16(entry.name.count))
            archive.appendLittleEndian(UInt16(0))            // extra
            archive.appendLittleEndian(UInt16(0))            // comment
            archive.appendLittleEndian(UInt16(0))            // disk number
            archive.appendLittleEndian(UInt16(0))            // internal attributes
            archive.appendLittleEndian(UInt32(0))            // external attributes
            archive.appendLittleEndian(entry.offset)
            archive.append(contentsOf: entry.name)
        }

        let directorySize = UInt32(archive.count) - directoryOffset
        archive.appendLittleEndian(UInt32(0x0605_4B50))      // end of central directory
        archive.appendLittleEndian(UInt16(0))                // this disk
        archive.appendLittleEndian(UInt16(0))                // disk with directory
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(UInt16(entries.count))
        archive.appendLittleEndian(directorySize)
        archive.appendLittleEndian(directoryOffset)
        archive.appendLittleEndian(UInt16(0))                // comment length
        return archive
    }
}

// MARK: - CRC32

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - 小端写入

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
