import Foundation

extension URLSession {
    /// Download a URL and stream progress through `progress(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)`.
    /// Creates a fresh session per call (so this is not a method on `URLSession.shared`).
    static func downloadWithProgress(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let delegate = DownloadProgressDelegate(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.download(from: url)
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: @Sendable (Int64, Int64, Int64) -> Void

    init(progress: @escaping @Sendable (Int64, Int64, Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(bytesWritten, totalBytesWritten, totalBytesExpectedToWrite)
    }
}
