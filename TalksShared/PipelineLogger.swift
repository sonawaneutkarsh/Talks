import Foundation

public struct PipelineLogger: Sendable {
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let formatterLock = NSLock()
    
    nonisolated(unsafe) public static var logListener: (@Sendable (String, UUID?, String) -> Void)?
    
    /// Builds one structured pipeline log line:
    /// `[<ISO-8601 timestamp>] [PIPELINE] [<stage>] [job: <first 8 chars of job ID or none>] [isMain: <Bool>] [<thread>] | <details>`
    /// The ` | <details>` suffix is omitted when `details` is empty.
    public static func formatLine(
        timestamp: Date,
        stage: String,
        jobId: UUID?,
        details: String,
        isMainThread: Bool,
        threadDescription: String
    ) -> String {
        formatterLock.lock()
        let stamp = dateFormatter.string(from: timestamp)
        formatterLock.unlock()
        let idStr = jobId.map { String($0.uuidString.prefix(8)) } ?? "none"
        let msg = details.isEmpty ? "" : " | \(details)"
        return "[\(stamp)] [PIPELINE] [\(stage)] [job: \(idStr)] [isMain: \(isMainThread)] [\(threadDescription)]\(msg)"
    }
    
    public static func log(stage: String, jobId: UUID? = nil, details: String = "") {
        let line = formatLine(
            timestamp: Date(),
            stage: stage,
            jobId: jobId,
            details: details,
            isMainThread: Thread.isMainThread,
            threadDescription: Thread.current.description
        )
        print(line)
        logListener?(stage, jobId, details)
    }
}
