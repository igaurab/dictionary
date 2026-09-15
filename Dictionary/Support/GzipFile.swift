import Foundation
import zlib

/// Streaming gzip decompression from one file to another.
///
/// `Zlib.gunzip` returns the whole result as `[UInt8]`, which is right for a
/// `.dict.dz` of a few megabytes but not for a downloaded dictionary that
/// inflates past a hundred — holding it and its source in memory at once is
/// how an import gets killed on a phone. This keeps a 256 KB window instead.
enum GzipFile {
    enum Failure: LocalizedError {
        case initFailed
        case corruptStream
        case unreadable

        var errorDescription: String? {
            switch self {
            case .initFailed: return "Could not start decompression."
            case .corruptStream: return "The downloaded file is corrupt."
            case .unreadable: return "The downloaded file could not be read."
            }
        }
    }

    /// True when the file begins with the gzip magic number.
    ///
    /// Sniffing beats trusting the catalogue: some hosts decompress a `.gz`
    /// transparently, and then the bytes on disk are already the database.
    static func isGzip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return head.count == 2 && head[head.startIndex] == 0x1f
            && head[head.startIndex + 1] == 0x8b
    }

    static func decompress(from source: URL, to destination: URL) throws {
        guard let input = try? FileHandle(forReadingFrom: source) else {
            throw Failure.unreadable
        }
        defer { try? input.close() }

        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else {
            throw Failure.unreadable
        }
        defer { try? output.close() }

        var stream = z_stream()
        // 47 = 15 window bits + 32, which lets zlib sniff gzip vs zlib headers.
        guard inflateInit2_(&stream, 47, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.initFailed
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 1 << 18
        let outBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { outBuffer.deallocate() }

        var finished = false
        while !finished {
            let inputChunk = (try? input.read(upToCount: chunkSize)) ?? Data()
            if inputChunk.isEmpty { break }

            var status: Int32 = Z_OK
            try inputChunk.withUnsafeBytes { raw in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                    throw Failure.corruptStream
                }
                stream.next_in = UnsafeMutablePointer(mutating: base)
                stream.avail_in = uInt(raw.count)

                repeat {
                    stream.next_out = outBuffer
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END
                            || status == Z_BUF_ERROR else {
                        throw Failure.corruptStream
                    }
                    let produced = chunkSize - Int(stream.avail_out)
                    if produced > 0 {
                        output.write(Data(bytes: outBuffer, count: produced))
                    }
                    if status == Z_STREAM_END {
                        finished = true
                        break
                    }
                    // No progress and nothing left to push: need more input.
                    if produced == 0 && stream.avail_in == 0 { break }
                } while stream.avail_in > 0 || stream.avail_out == 0
            }
        }

        // A download cut short inflates cleanly right up to the point it stops,
        // so "never reached the end of the stream" is the only truncation signal.
        guard finished else { throw Failure.corruptStream }
    }
}
