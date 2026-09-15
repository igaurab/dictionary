import Foundation
import zlib

/// Thin wrapper over the system zlib, which iOS links automatically through
/// the SDK module map. Used to inflate `.dict.dz` (dictzip, a gzip variant)
/// and deflated ZIP members without pulling in a third-party dependency.
enum Zlib {
    enum Failure: Error {
        case initFailed
        case corruptStream
    }

    /// Inflates a gzip or zlib stream. dictzip stores its random-access table
    /// in the gzip FEXTRA field, which a normal inflate simply skips — so the
    /// whole `.dict.dz` decompresses like any other gzip file.
    static func gunzip(_ input: Data) throws -> [UInt8] {
        // 47 = 15 window bits + 32, which tells zlib to sniff gzip vs zlib headers.
        try run(input, windowBits: 47, sizeHint: input.count * 4)
    }

    /// Inflates a headerless deflate stream, which is how ZIP stores members.
    static func rawInflate(_ input: Data, sizeHint: Int) throws -> [UInt8] {
        try run(input, windowBits: -15, sizeHint: sizeHint)
    }

    private static func run(_ input: Data, windowBits: Int32, sizeHint: Int) throws -> [UInt8] {
        guard !input.isEmpty else { return [] }

        var stream = z_stream()
        guard inflateInit2_(&stream, windowBits, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.initFailed
        }
        defer { inflateEnd(&stream) }

        let chunkSize = 1 << 18
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        var output = [UInt8]()
        output.reserveCapacity(max(sizeHint, chunkSize))

        try input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw Failure.corruptStream
            }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(raw.count)

            while true {
                stream.next_out = chunk
                stream.avail_out = uInt(chunkSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw Failure.corruptStream
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: UnsafeBufferPointer(start: chunk, count: produced))
                }
                if status == Z_STREAM_END { break }
                // No progress and nothing left to feed: truncated stream, stop
                // with what we have rather than spinning forever.
                if produced == 0 && stream.avail_in == 0 { break }
            }
        }
        return output
    }
}
