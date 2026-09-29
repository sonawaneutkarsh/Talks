import Foundation

public struct PipelineLogger: Sendable {
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    nonisolated(unsafe) public static var logListener: (@Sendable (String, UUID?, String) -> Void)?
    
    public static func log(stage: String, jobId: UUID? = nil, details: String = "") {
        let timestamp = dateFormatter.string(from: Date())
        let isMain = Thread.isMainThread
        let threadDesc = Thread.current.description
        let idStr = jobId.map { $0.uuidString.prefix(8).description } ?? "none"
        let msg = details.isEmpty ? "" : " | \(details)"
        print("[\(timestamp)] [PIPELINE] [\(stage)] [job: \(idStr)] [isMain: \(isMain)] [\(threadDesc)]\(msg)")
        logListener?(stage, jobId, details)
    }
}
