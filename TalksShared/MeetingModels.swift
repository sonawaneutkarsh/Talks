import Foundation

public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case waitingForTransfer = "waitingForTransfer"
    case received = "received"
    case transcribing = "transcribing"
    case waitingForAI = "waitingForAI"
    case formatting = "formatting"
    case waitingForNotion = "waitingForNotion"
    case uploadingToNotion = "uploadingToNotion"
    case completed = "completed"
    case failed = "failed"
    
    public var displayText: String {
        switch self {
        case .waitingForTransfer:
            return "Waiting for transfer"
        case .received:
            return "Received on iPhone"
        case .transcribing:
            return "🎙️ Transcribing"
        case .waitingForAI:
            return "⏳ Waiting for Apple Intelligence"
        case .formatting:
            return "✨ Formatting with AI"
        case .waitingForNotion:
            return "☁️ Waiting for Notion"
        case .uploadingToNotion:
            return "☁️ Uploading to Notion"
        case .completed:
            return "✅ Saved to Notion"
        case .failed:
            return "⚠️ Needs Attention"
        }
    }
    
    public var isTerminal: Bool {
        self == .completed
    }
    
    public var isEligibleForDeletion: Bool {
        self == .completed || self == .failed
    }
}

public struct MeetingIntelligence: Codable, Sendable, Equatable {
    public var summary: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [String]
    public var followUps: [String]
    
    public init(
        summary: String = "",
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [String] = [],
        followUps: [String] = []
    ) {
        self.summary = summary
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.followUps = followUps
    }
}

public struct MeetingJob: Identifiable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var duration: TimeInterval
    public var localAudioRelativePath: String?
    
    // Invariant: rawTranscript is untouched once written!
    public var rawTranscript: String?
    public var aiFormattedTranscript: String?
    public var intelligence: MeetingIntelligence?
    public var title: String?
    
    // Notion idempotency tracking
    public var notionPageId: String?
    public var notionPageUrl: String?
    
    public var status: JobStatus
    public var lastAttemptDate: Date?
    public var retryCount: Int
    public var errorMessage: String?
    
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        localAudioRelativePath: String? = nil,
        rawTranscript: String? = nil,
        aiFormattedTranscript: String? = nil,
        intelligence: MeetingIntelligence? = nil,
        title: String? = nil,
        notionPageId: String? = nil,
        notionPageUrl: String? = nil,
        status: JobStatus = .received,
        lastAttemptDate: Date? = nil,
        retryCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.localAudioRelativePath = localAudioRelativePath
        self.rawTranscript = rawTranscript
        self.aiFormattedTranscript = aiFormattedTranscript
        self.intelligence = intelligence
        self.title = title
        self.notionPageId = notionPageId
        self.notionPageUrl = notionPageUrl
        self.status = status
        self.lastAttemptDate = lastAttemptDate
        self.retryCount = retryCount
        self.errorMessage = errorMessage
    }
    
    public var displayTitle: String {
        if let title = title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Talk — \(formatter.string(from: createdAt))"
    }
}
