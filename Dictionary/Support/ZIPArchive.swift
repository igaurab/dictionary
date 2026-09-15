import Foundation

/// Minimal read-only ZIP extractor for the stored and deflated methods, which
/// is everything a StarDict download uses in practice.
///
/// iOS has no public unzip API and the app takes no third-party dependencies,
/// so the central directory is parsed by hand. Every read is bounds-checked
/// because the archive comes from the user and cannot be trusted.
enum ZIPArchive {
    enum Failure: Error {
        case notAZIP
        case unsupportedZIP64
        case unsupportedCompression(UInt16)
        case malformed
        case unsafeEntryPath(String)
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50

    /// Extracts every regular file into `directory`, recreating the archive's
    /// folder structure. Returns the paths written.
    @discardableResult
    static func extract(_ archive: URL, into directory: URL) throws -> [URL] {
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let bytes = [UInt8](data)
        let eocd = try locateEndOfCentralDirectory(bytes)

        let entryCount = Int(try readUInt16(bytes, eocd + 10))
        var offset = Int(try readUInt32(bytes, eocd + 16))
        guard offset != Int(UInt32.max) else { throw Failure.unsupportedZIP64 }

        var written: [URL] = []
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for _ in 0..<entryCount {
            guard try readUInt32(bytes, offset) == centralFileHeaderSignature else {
                throw Failure.malformed
            }
            let method = try readUInt16(bytes, offset + 10)
            var compressedSize = Int(try readUInt32(bytes, offset + 20))
            var uncompressedSize = Int(try readUInt32(bytes, offset + 24))
            let nameLength = Int(try readUInt16(bytes, offset + 28))
            let extraLength = Int(try readUInt16(bytes, offset + 30))
            let commentLength = Int(try readUInt16(bytes, offset + 32))
            var localOffset = Int(try readUInt32(bytes, offset + 42))

            let nameStart = offset + 46
            try requireRange(bytes, nameStart, nameLength)
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            let extraStart = nameStart + nameLength
            try requireRange(bytes, extraStart, extraLength)
            if compressedSize == Int(UInt32.max) || uncompressedSize == Int(UInt32.max)
                || localOffset == Int(UInt32.max) {
                try applyZIP64Extra(bytes, start: extraStart, length: extraLength,
                                    uncompressedSize: &uncompressedSize,
                                    compressedSize: &compressedSize,
                                    localOffset: &localOffset)
            }

            offset = extraStart + extraLength + commentLength

            // Directory entries carry no payload; the tree is made on demand.
            if name.hasSuffix("/") || name.isEmpty { continue }
            let destination = try resolvedDestination(for: name, in: directory)

            guard try readUInt32(bytes, localOffset) == localFileHeaderSignature else {
                throw Failure.malformed
            }
            let localNameLength = Int(try readUInt16(bytes, localOffset + 26))
            let localExtraLength = Int(try readUInt16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            try requireRange(bytes, dataStart, compressedSize)
            let payload = data.subdata(in: dataStart..<(dataStart + compressedSize))

            let contents: Data
            switch method {
            case 0:
                contents = payload
            case 8:
                contents = Data(try Zlib.rawInflate(payload, sizeHint: uncompressedSize))
            default:
                throw Failure.unsupportedCompression(method)
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: destination)
            written.append(destination)
        }
        return written
    }

    // MARK: - Private

    /// Rejects absolute paths and `..` traversal so a hostile archive cannot
    /// write outside the destination directory.
    private static func resolvedDestination(for name: String, in directory: URL) throws -> URL {
        let components = name.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !name.hasPrefix("/"),
              !components.contains(".."),
              !components.contains(".")
        else { throw Failure.unsafeEntryPath(name) }

        var url = directory
        for component in components { url.appendPathComponent(component) }

        let root = directory.standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(root) else {
            throw Failure.unsafeEntryPath(name)
        }
        return url
    }

    private static func applyZIP64Extra(_ bytes: [UInt8], start: Int, length: Int,
                                        uncompressedSize: inout Int,
                                        compressedSize: inout Int,
                                        localOffset: inout Int) throws {
        var cursor = start
        let end = start + length
        while cursor + 4 <= end {
            let headerID = try readUInt16(bytes, cursor)
            let size = Int(try readUInt16(bytes, cursor + 2))
            let body = cursor + 4
            guard body + size <= end else { throw Failure.malformed }
            if headerID == 0x0001 {
                // Fields appear only for the 0xFFFFFFFF placeholders, in this order.
                var field = body
                if uncompressedSize == Int(UInt32.max), field + 8 <= body + size {
                    uncompressedSize = try intValue(readUInt64(bytes, field)); field += 8
                }
                if compressedSize == Int(UInt32.max), field + 8 <= body + size {
                    compressedSize = try intValue(readUInt64(bytes, field)); field += 8
                }
                if localOffset == Int(UInt32.max), field + 8 <= body + size {
                    localOffset = try intValue(readUInt64(bytes, field))
                }
                return
            }
            cursor = body + size
        }
        throw Failure.unsupportedZIP64
    }

    private static func intValue(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else { throw Failure.malformed }
        return Int(value)
    }

    /// The end-of-central-directory record sits at the tail, after a comment of
    /// up to 64 KB, so it is found by scanning backwards for its signature.
    private static func locateEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw Failure.notAZIP }
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        var index = bytes.count - 22
        while index >= lowest {
            if (try? readUInt32(bytes, index)) == endOfCentralDirectorySignature {
                return index
            }
            index -= 1
        }
        throw Failure.notAZIP
    }

    private static func requireRange(_ bytes: [UInt8], _ start: Int, _ count: Int) throws {
        guard start >= 0, count >= 0, start <= bytes.count, bytes.count - start >= count else {
            throw Failure.malformed
        }
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) throws -> UInt16 {
        try requireRange(bytes, offset, 2)
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        try requireRange(bytes, offset, 4)
        var value: UInt32 = 0
        for shift in 0..<4 { value |= UInt32(bytes[offset + shift]) << (8 * UInt32(shift)) }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) throws -> UInt64 {
        try requireRange(bytes, offset, 8)
        var value: UInt64 = 0
        for shift in 0..<8 { value |= UInt64(bytes[offset + shift]) << (8 * UInt64(shift)) }
        return value
    }
}
