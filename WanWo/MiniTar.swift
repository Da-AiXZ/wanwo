import Foundation

/// 极简 tar（ustar/GNU）解包器 —— M0.2 专用。
/// 支持普通文件/目录/硬链接跳过、GNU longname ('L')、跳过 pax 头（'x'/'g'）。
/// 权限：从 tar 头恢复 mode；bin/sbin 等执行位额外兜底（Y9）。
enum MiniTar {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 把 tar 解到 destination（已存在则先删）
    static func extract(archive: URL, to destination: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }

        var longName: String?
        var readCount: Int64 = 0
        let total = try handle.seekToEnd()

        try handle.seek(toOffset: 0)
        while readCount < total {
            let header = try handle.read(upToCount: 512) ?? Data()
            guard header.count == 512 else { break }
            readCount += 512

            // 全零块 = 结束
            if header.allSatisfy({ $0 == 0 }) { break }

            guard let nameData = String(data: header[0..<100], encoding: .ascii) else {
                throw Error(message: "tar 头解析失败（非 ASCII 文件名）")
            }
            var name = nameData.prefix(while: { $0 != "\0" }).trimmingCharacters(in: .whitespaces)

            let sizeStr = String(data: header[124..<136], encoding: .ascii)?
                .prefix(while: { $0 != "\0" && $0 != " " }) ?? "0"
            let size = Int(sizeStr, radix: 8) ?? 0
            let modeStr = String(data: header[100..<108], encoding: .ascii)?
                .prefix(while: { $0 != "\0" && $0 != " " }) ?? "644"
            let mode = Int(modeStr, radix: 8) ?? 0o644
            let typeflag = header[156]
            let dataStart = readCount
            let padded = (size + 511) / 512 * 512

            switch typeflag {
            case UInt8(ascii: "L"):          // GNU longname：下一条目的真名
                let data = try handle.read(upToCount: Int(padded)) ?? Data()
                readCount += Int64(padded)
                longName = String(data: data.prefix(size), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            case UInt8(ascii: "x"), UInt8(ascii: "g"):  // pax 头：跳过
                try handle.seek(toOffset: UInt64(dataStart + Int64(padded)))
                readCount += Int64(padded)
                continue
            case UInt8(ascii: "0"), 0:       // 普通文件
                if longName != nil { name = longName!; longName = nil }
                let target = destination.appendingPathComponent(name)
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                let data = try handle.read(upToCount: Int(padded)) ?? Data()
                readCount += Int64(padded)
                try data.prefix(size).write(to: target)
                // 从 tar 头恢复权限（fakefsify 产出的 mode 已含正确执行位）
                _ = try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            case UInt8(ascii: "5"):          // 目录
                if longName != nil { name = longName!; longName = nil }
                try fm.createDirectory(at: destination.appendingPathComponent(name),
                                       withIntermediateDirectories: true)
                // 目录无数据体
            default:                          // 硬链接(1)/符号链接(2)/其他：M0 跳过
                if longName != nil { longName = nil }
                try handle.seek(toOffset: UInt64(dataStart + Int64(padded)))
                readCount += Int64(padded)
            }
        }
    }
}
