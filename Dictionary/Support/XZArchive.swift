import Foundation
import Compression

/// Decompresses `.xz` streams with Apple's Compression framework.
///
/// `COMPRESSION_LZMA` is documented only as "LZMA", which is ambiguous — but it
/// is the `.xz` container (magic `FD 37 7A 58 5A 00`), not a bare LZMA1 stream.
/// Checked against every archive in the download catalogue: each one decodes to
/// exactly the same bytes as the `xz` command line tool, so no third-party
/// liblzma is needed.
enum XZArchive {
    enum Failure: Error {
        case notXZ
        case corruptStream
        case tooLarge
    }

    static let magic: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]

    static func hasMagic(_ data: Data) -> Bool {
        guard data.count >= magic.count else { return false }
        let start = data.startIndex
        return (0..<magic.count).allSatisfy { data[start + $0] == magic[$0] }
    }

    /// - Parameter limit: hard ceiling on the decompressed size. These archives
    ///   are downloaded from the network, so a crafted one must not be able to
    ///   expand until the app is killed.
    static func decompress(_ input: Data, limit: Int = 512 << 20) throws -> Data {
        guard hasMagic(input) else { throw Failure.notXZ }

        var output = Data()
        // Compression ratios here range from barely any to better than 5:1, so
        // this is only a head start on the geometric growth Data does anyway —
        // capped so a large archive does not reserve hundreds of unused MB.
        output.reserveCapacity(min(limit, min(input.count * 2, 64 << 20)))

        try input.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw Failure.corruptStream
            }
            let total = raw.count
            var cursor = 0

            // .xz streams may be concatenated, each padded with NUL bytes to a
            // four-byte boundary; a stream itself never starts with a NUL.
            while cursor < total {
                while cursor < total, base[cursor] == 0 { cursor += 1 }
                guard cursor < total else { break }
                guard total - cursor >= magic.count,
                      (0..<magic.count).allSatisfy({ base[cursor + $0] == magic[$0] })
                else { throw Failure.corruptStream }

                cursor += try decodeStream(base + cursor, count: total - cursor,
                                           into: &output, limit: limit)
            }
        }
        return output
    }

    /// Decodes one stream and returns how many input bytes it consumed.
    private static func decodeStream(_ source: UnsafePointer<UInt8>, count: Int,
                                     into output: inout Data, limit: Int) throws -> Int {
        // compression_stream has no usable Swift initialiser, so it is built in
        // place and torn down by compression_stream_destroy.
        let state = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { state.deallocate() }
        guard compression_stream_init(state, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA)
                == COMPRESSION_STATUS_OK else { throw Failure.corruptStream }
        defer { compression_stream_destroy(state) }

        state.pointee.src_ptr = source
        state.pointee.src_size = count

        let chunkSize = 1 << 18
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { chunk.deallocate() }

        while true {
            state.pointee.dst_ptr = chunk
            state.pointee.dst_size = chunkSize
            let status = compression_stream_process(
                state, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))

            let produced = chunkSize - state.pointee.dst_size
            if produced > 0 {
                guard output.count + produced <= limit else { throw Failure.tooLarge }
                output.append(chunk, count: produced)
            }

            switch status {
            case COMPRESSION_STATUS_END:
                return count - state.pointee.src_size
            case COMPRESSION_STATUS_OK:
                // Neither consuming nor producing means the stream ended early.
                // Fail rather than return a half-decoded dictionary.
                if produced == 0, state.pointee.src_size == 0 { throw Failure.corruptStream }
            default:
                throw Failure.corruptStream
            }
        }
    }
}
