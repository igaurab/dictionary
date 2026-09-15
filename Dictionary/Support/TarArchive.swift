import Foundation

/// Minimal read-only reader for the ustar (POSIX tar) format, which is how
/// StarDict dictionaries are distributed once the `.xz` layer is peeled off.
///
/// Like `ZIPArchive`, this parses bytes that came off the network, so every
/// read is bounds-checked and anything unexpected fails closed rather than
/// producing a half-extracted tree.
enum TarArchive {
    enum Failure: Error {
        case malformed
        case unsafeEntryPath(String)
        case empty
    }

    private static let blockSize = 512

    // ustar header field offsets.
    private static let sizeOffset = 124
    private static let checksumOffset = 148
    private static let typeFlagOffset = 156
    private static let magicOffset = 257
    private static let prefixOffset = 345

    /// Extracts every regular file into `directory`, recreating the archive's
    /// folder structure. Returns the paths written.
    @discardableResult
    static func extract(_ archive: Data, into directory: URL) throws -> [URL] {
        let bytes = Bytes(archive)
        var cursor = 0
        var written: [URL] = []

        // A GNU 'L' header carries an over-long name for the entry after it.
        var pendingLongName: String?

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        while bytes.count - cursor >= blockSize {
            let header = cursor
            // Two NUL blocks end the archive; one is enough to stop on.
            if isZeroBlock(bytes, at: header) { break }
            guard checksumIsValid(bytes, at: header) else { throw Failure.malformed }
            cursor += blockSize

            let size = try octal(bytes, at: header + sizeOffset, length: 12)
            guard size >= 0, bytes.count - cursor >= size else { throw Failure.malformed }
            let payload = cursor
            // Entry bodies are padded out to a whole number of blocks.
            cursor = min(cursor + (size + blockSize - 1) / blockSize * blockSize, bytes.count)

            switch bytes[header + typeFlagOffset] {
            case UInt8(ascii: "L"):
                pendingLongName = string(bytes, at: payload, length: size)
                continue
            case UInt8(ascii: "x"):
                // A pax extended header overrides fields of the entry after it.
                // Only "path" matters here; everything else is metadata a
                // dictionary import has no use for.
                if let path = paxPath(bytes.slice(payload, size)) { pendingLongName = path }
                continue
            case UInt8(ascii: "K"), UInt8(ascii: "g"):
                // Long link targets are for entry types that are dropped below,
                // and a global header applies defaults this reader ignores.
                continue
            default:
                break
            }

            let name = pendingLongName ?? entryName(bytes, at: header)
            pendingLongName = nil
            guard !name.isEmpty else { continue }

            switch bytes[header + typeFlagOffset] {
            case 0, UInt8(ascii: "0"):
                let destination = try resolvedDestination(for: name, in: directory)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.slice(payload, size).write(to: destination)
                written.append(destination)
            case UInt8(ascii: "5"):
                let destination = try resolvedDestination(for: name, in: directory)
                try FileManager.default.createDirectory(at: destination,
                                                        withIntermediateDirectories: true)
            default:
                // Symlinks, hard links, devices and FIFOs are never part of a
                // StarDict dictionary and are the classic archive attack, so
                // they are dropped rather than recreated.
                break
            }
        }

        guard !written.isEmpty else { throw Failure.empty }
        return written
    }

    /// True when the data plausibly begins with a tar header, used to recognise
    /// an archive whose name lost its extension.
    static func hasUstarMagic(_ data: Data) -> Bool {
        guard data.count >= blockSize else { return false }
        let bytes = Bytes(data)
        return bytes[magicOffset] == UInt8(ascii: "u")
            && bytes[magicOffset + 1] == UInt8(ascii: "s")
            && bytes[magicOffset + 2] == UInt8(ascii: "t")
            && bytes[magicOffset + 3] == UInt8(ascii: "a")
            && bytes[magicOffset + 4] == UInt8(ascii: "r")
    }

    // MARK: - Header fields

    /// ustar splits long paths into a 155-byte prefix and a 100-byte name.
    private static func entryName(_ bytes: Bytes, at header: Int) -> String {
        let name = string(bytes, at: header, length: 100)
        guard bytes[header + magicOffset] == UInt8(ascii: "u") else { return name }
        let prefix = string(bytes, at: header + prefixOffset, length: 155)
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    /// The stored checksum is the sum of every header byte with the checksum
    /// field itself read as spaces. Historic writers disagreed on whether the
    /// bytes are signed, so both readings are accepted.
    private static func checksumIsValid(_ bytes: Bytes, at header: Int) -> Bool {
        guard let stored = try? octal(bytes, at: header + checksumOffset, length: 8) else {
            return false
        }
        var unsigned = 0
        var signed = 0
        for index in 0..<blockSize {
            let byte = (index >= checksumOffset && index < checksumOffset + 8)
                ? UInt8(ascii: " ") : bytes[header + index]
            unsigned += Int(byte)
            signed += Int(Int8(bitPattern: byte))
        }
        return stored == unsigned || stored == signed
    }

    /// Numeric fields are NUL/space padded octal. GNU tar switches to base-256
    /// (high bit of the first byte set) for values that do not fit.
    private static func octal(_ bytes: Bytes, at offset: Int, length: Int) throws -> Int {
        guard offset >= 0, length >= 0, bytes.count - offset >= length else {
            throw Failure.malformed
        }
        if bytes[offset] & 0x80 != 0 {
            var value = 0
            for index in 1..<length {
                let (shifted, overflow) = value.multipliedReportingOverflow(by: 256)
                guard !overflow else { throw Failure.malformed }
                value = shifted + Int(bytes[offset + index])
            }
            return value
        }

        var value = 0
        var sawDigit = false
        for index in 0..<length {
            let byte = bytes[offset + index]
            if byte == 0 || byte == UInt8(ascii: " ") {
                if sawDigit { break }
                continue
            }
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "7") else {
                throw Failure.malformed
            }
            let (shifted, overflow) = value.multipliedReportingOverflow(by: 8)
            guard !overflow else { throw Failure.malformed }
            value = shifted + Int(byte - UInt8(ascii: "0"))
            sawDigit = true
        }
        return sawDigit ? value : 0
    }

    private static func string(_ bytes: Bytes, at offset: Int, length: Int) -> String {
        guard offset >= 0, length > 0, bytes.count - offset >= length else { return "" }
        var end = offset
        let limit = offset + length
        while end < limit, bytes[end] != 0 { end += 1 }
        return String(decoding: bytes.slice(offset, end - offset), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Pulls the overriding path out of a pax extended header, whose body is a
    /// run of `"<length> <keyword>=<value>\n"` records with `length` counted in
    /// bytes, including the length field itself.
    private static func paxPath(_ record: Data) -> String? {
        let bytes = Bytes(record)
        var cursor = 0
        let key = Array("path=".utf8)

        while cursor < bytes.count {
            var space = cursor
            while space < bytes.count, bytes[space] != UInt8(ascii: " ") { space += 1 }
            guard space < bytes.count,
                  let length = Int(String(decoding: bytes.slice(cursor, space - cursor),
                                          as: UTF8.self)),
                  length > space - cursor, bytes.count - cursor >= length
            else { return nil }

            let bodyStart = space + 1
            let bodyLength = cursor + length - bodyStart
            guard bodyLength > key.count else { cursor += length; continue }

            let body = bytes.slice(bodyStart, bodyLength)
            if Array(body.prefix(key.count)) == key {
                let path = String(decoding: body.dropFirst(key.count), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
            cursor += length
        }
        return nil
    }

    private static func isZeroBlock(_ bytes: Bytes, at offset: Int) -> Bool {
        for index in 0..<blockSize where bytes[offset + index] != 0 { return false }
        return true
    }

    // MARK: - Paths

    /// Rejects absolute paths and `..` traversal, so a hostile archive cannot
    /// write outside the destination directory. Same rules as `ZIPArchive`.
    private static func resolvedDestination(for name: String, in directory: URL) throws -> URL {
        let components = name.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !name.hasPrefix("/"),
              !name.hasPrefix("~"),
              !components.contains(".."),
              !components.contains(".")
        else { throw Failure.unsafeEntryPath(name) }

        var url = directory
        for component in components { url.appendPathComponent(component) }

        // Compared as path components rather than as a string prefix, so a
        // sibling directory whose name merely starts the same way cannot pass.
        //
        // `standardized` is deliberately used over `standardizedFileURL`: the
        // latter consults the filesystem, which resolves /private/tmp to /tmp
        // for the destination that already exists but not for the entry that
        // does not yet, so the two sides would never line up.
        let root = directory.standardized.pathComponents
        let resolved = url.standardized.pathComponents
        guard resolved.count > root.count,
              Array(resolved.prefix(root.count)) == root
        else { throw Failure.unsafeEntryPath(name) }
        return url
    }

    // MARK: - Bytes

    /// `Data` slices do not start at index zero, and a whole decompressed
    /// archive is far too big to copy into an array, so reads go through this.
    private struct Bytes {
        private let data: Data
        private let base: Data.Index

        init(_ data: Data) {
            self.data = data
            self.base = data.startIndex
        }

        var count: Int { data.count }

        subscript(index: Int) -> UInt8 {
            index >= 0 && index < data.count ? data[base + index] : 0
        }

        func slice(_ offset: Int, _ length: Int) -> Data {
            guard offset >= 0, length > 0, data.count - offset >= length else { return Data() }
            return data.subdata(in: (base + offset)..<(base + offset + length))
        }
    }
}
