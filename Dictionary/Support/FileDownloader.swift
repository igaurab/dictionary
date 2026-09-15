import Foundation

enum FileDownloadError: LocalizedError {
    case offline
    case badStatus(Int)
    case truncated
    case cancelled
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "No internet connection. Connect and try again."
        case .badStatus(404):
            return "The dictionary is no longer available at that address (404)."
        case .badStatus(let code):
            return "The server refused the download (HTTP \(code))."
        case .truncated:
            return "The download ended early. Check your connection and try again."
        case .cancelled:
            return "The download was cancelled."
        case .transport(let detail):
            return detail
        }
    }
}

/// Downloads one file to a temporary location, reporting real progress.
///
/// `URLSession.bytes` only yields one byte at a time, which is unusable for a
/// twenty-megabyte dictionary, so this goes through a download task and reads
/// its `Progress` instead.
enum FileDownloader {
    /// Downloads `url` and moves the result to a temporary file the caller owns.
    static func download(
        from url: URL,
        expectedBytes: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("download-\(UUID().uuidString)")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }

        let downloaded: URL = try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url) { temporaryURL, response, error in
                if let error = error as? URLError {
                    switch error.code {
                    case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                         .networkConnectionLost, .dataNotAllowed:
                        continuation.resume(throwing: FileDownloadError.offline)
                    case .cancelled:
                        continuation.resume(throwing: FileDownloadError.cancelled)
                    default:
                        continuation.resume(
                            throwing: FileDownloadError.transport(error.localizedDescription))
                    }
                    return
                }
                if let error {
                    continuation.resume(
                        throwing: FileDownloadError.transport(error.localizedDescription))
                    return
                }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: FileDownloadError.badStatus(http.statusCode))
                    return
                }
                guard let temporaryURL else {
                    continuation.resume(throwing: FileDownloadError.truncated)
                    return
                }
                // The system deletes this file as soon as the handler returns,
                // so it has to be moved here rather than after the await.
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(
                        throwing: FileDownloadError.transport(error.localizedDescription))
                }
            }
            observation = task.progress.observe(\.fractionCompleted) { value, _ in
                progress(value.fractionCompleted)
            }
            task.resume()
        }

        // A connection dropped mid-transfer still hands back the bytes it got.
        if let expectedBytes, expectedBytes > 0 {
            let size = (try? FileManager.default
                .attributesOfItem(atPath: downloaded.path)[.size] as? Int64) ?? nil
            if let size, size < expectedBytes / 2 {
                try? FileManager.default.removeItem(at: downloaded)
                throw FileDownloadError.truncated
            }
        }
        progress(1)
        return downloaded
    }
}
