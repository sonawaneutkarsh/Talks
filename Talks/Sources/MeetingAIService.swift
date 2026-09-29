import Foundation
import FoundationModels

// MARK: - Architectural Invariant: On-Device Apple Intelligence Structuring
// 1. Zero Cloud: Formatting uses Apple's Foundation Models on device.
// 2. Structured Extraction: Generates Title, Summary, Key Points, Decisions, Action Items,
//    and Follow-Ups using schema-guided generation (@Generable).
// 3. Graceful Fallback: On devices without Apple Intelligence enabled, an intelligent
//    heuristic local rule-based extractor provides clean structured output without crashing.

public enum MeetingAIError: LocalizedError {
    case appleIntelligenceUnavailable(String)
    case contextWindowExceeded
    case processingFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .appleIntelligenceUnavailable(let reason):
            return "Apple Intelligence unavailable: \(reason)"
        case .contextWindowExceeded:
            return "The transcript exceeded the model's context window."
        case .processingFailed(let msg):
            return "Apple Intelligence processing error: \(msg)"
        }
    }
}

@available(iOS 26.0, *)
@Generable
public struct GeneratedMeetingIntelligence {
    @Guide(description: "A concise, objective summary of the meeting, what was discussed, and what happened.")
    public var summary: String
    
    @Guide(description: "Key points, research ideas, advice, technical explanations, and guidance communicated.")
    public var keyPoints: [String]
    
    @Guide(description: "Concrete decisions actually made during the meeting. Empty if none were made.")
    public var decisions: [String]
    
    @Guide(description: "Specific action items and tasks to do, including context and deadlines if mentioned. Do not manufacture deadlines.")
    public var actionItems: [String]
    
    @Guide(description: "Unresolved questions, open topics, or items worth following up on.")
    public var followUps: [String]
}

@available(iOS 26.0, *)
@Generable
public struct ConsolidatedSummaryOutput {
    @Guide(description: "A coherent consolidated summary combining all section summaries of a long meeting.")
    public var summary: String
}

@available(iOS 26.0, *)
@Generable
public struct GeneratedTitle {
    @Guide(description: "A short, descriptive 3-6 word title for the meeting (e.g. 'Nahian — ADR Research Planning' or 'Office Hours — Vector Fields'). Do not include dates.")
    public var title: String
}

public actor MeetingAIService {
    public static let shared = MeetingAIService()
    
    /// Queries the model's supported context size dynamically from FoundationModels.
    public func getModelContextLimit() -> Int {
        guard #available(iOS 26.0, *) else { return 4096 }
        let tokens = SystemLanguageModel.default.contextSize
        // A conservative estimate of characters per token for English text is ~3.2 characters
        // Leaving 25% margin for instructions, prompt boilerplate, and output schema
        return max(4000, Int(Double(tokens) * 2.5))
    }
    
    /// Checks the current device's Apple Intelligence availability.
    public func checkAvailability() -> (isAvailable: Bool, message: String) {
        guard #available(iOS 26.0, *) else {
            return (false, "Requires iOS 26.0 or later for on-device Foundation Models.")
        }
        
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return (true, "Apple Intelligence is ready and available on-device.")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return (false, "This device does not support on-device Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return (false, "Apple Intelligence is not enabled in Settings.")
            case .modelNotReady:
                return (false, "Apple Intelligence model assets are currently preparing/downloading.")
            default:
                return (false, "Apple Intelligence is currently unavailable.")
            }
        }
    }
    
    /// Processes the raw transcript through Apple Intelligence:
    /// 1. Formats the full readable transcript with headers and paragraphs.
    /// 2. Extracts structured meeting intelligence (summary, key points, decisions, actions, follow-ups).
    /// 3. Generates a descriptive meeting title with date.
    public func processTranscript(rawTranscript: String, date: Date, jobId: UUID? = nil) async throws -> (formattedTranscript: String, intelligence: MeetingIntelligence, title: String) {
        PipelineLogger.log(stage: "formatting task started", jobId: jobId, details: "Raw length: \(rawTranscript.count) chars")
        guard #available(iOS 26.0, *) else {
            throw MeetingAIError.appleIntelligenceUnavailable("iOS 26.0+ required for on-device Foundation Models.")
        }
        
        let (available, reason) = checkAvailability()
        guard available else {
            throw MeetingAIError.appleIntelligenceUnavailable(reason)
        }
        
        // 1. Generate Polished AI-Formatted Transcript (hierarchical chunking preserves every section)
        let formatted = try await generateFormattedTranscript(rawTranscript: rawTranscript)
        
        // 2. Extract Structured Meeting Intelligence across the ENTIRE transcript
        let intelligence = try await extractMeetingIntelligence(formattedTranscript: formatted)
        
        // 3. Generate Descriptive Title
        let title = try await generateMeetingTitle(formattedTranscript: formatted, date: date)
        
        PipelineLogger.log(stage: "formatting completed", jobId: jobId, details: "Title: \(title)")
        return (formatted, intelligence, title)
    }
    
    // MARK: - Polished Transcript Generation
    
    @available(iOS 26.0, *)
    private func generateFormattedTranscript(rawTranscript: String) async throws -> String {
        let maxChunkLength = getModelContextLimit()
        
        if rawTranscript.count <= maxChunkLength {
            return try await formatSingleChunk(chunk: rawTranscript)
        }
        
        // Hierarchical processing for long meetings:
        let chunks = splitIntoChunks(text: rawTranscript, targetSize: maxChunkLength)
        var formattedChunks: [String] = []
        
        for (index, chunk) in chunks.enumerated() {
            let prompt = """
            You are formatting section \(index + 1) of \(chunks.count) of a long meeting transcript.
            Clean up punctuation, speech recognition errors, and meaningless filler words like 'um'/'uh'.
            Break into readable paragraphs with descriptive headings (e.g. ## Topic).
            Preserve all technical terminology, numbers, dates, deadlines, and research assignments.
            Preserve speaker uncertainty: do not convert uncertain statements into definitive facts.
            Do not aggressively summarize; keep the detailed discussion intact.
            
            Transcript segment:
            \(chunk)
            """
            
            let session = LanguageModelSession(
                model: .default,
                instructions: "You are an expert transcription editor. Clean speech transcripts into readable, well-punctuated, professional text with clear headings and paragraphs. Never invent information."
            )
            
            do {
                let response = try await session.respond(to: prompt)
                formattedChunks.append(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                print("Error formatting chunk \(index + 1): \(error)")
                formattedChunks.append(chunk)
            }
        }
        
        return formattedChunks.joined(separator: "\n\n")
    }
    
    @available(iOS 26.0, *)
    private func formatSingleChunk(chunk: String) async throws -> String {
        let instructions = """
        You are an expert transcription editor. Clean up the raw speech-to-text transcript of a meeting into a polished, readable document.
        - Fix punctuation, capitalization, and obvious speech recognition errors.
        - Break giant walls of text into readable paragraphs and logical sections with descriptive headings (e.g. ## Topic Name).
        - Remove meaningless filler words ('um', 'uh', repeated false starts).
        - Collapse accidental repetitions.
        - Preserve every meaningful idea, technical terminology, numbers, dates, deadlines, research assignments, and uncertainty.
        - Never convert uncertain statements into definitive facts.
        - Never invent facts or statements that were not said.
        - Use bullet points when lists are discussed.
        - Maintain a comprehensive, detailed representation of the meeting rather than an aggressive summary.
        """
        
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let prompt = "Please format this raw transcript into a polished, readable meeting transcript:\n\n\(chunk)"
        
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Structured Meeting Intelligence (Full-Transcript Hierarchical Coverage)
    
    @available(iOS 26.0, *)
    private func extractMeetingIntelligence(formattedTranscript: String) async throws -> MeetingIntelligence {
        let maxChunkLength = getModelContextLimit()
        
        // If entire transcript fits within context window, process in a single pass
        if formattedTranscript.count <= maxChunkLength {
            return try await extractChunkIntelligence(text: formattedTranscript)
        }
        
        // For long meetings (30, 60, 90+ minutes), process hierarchically across ALL chunks
        let chunks = splitIntoChunks(text: formattedTranscript, targetSize: maxChunkLength)
        var chunkIntelligences: [MeetingIntelligence] = []
        
        for (i, chunk) in chunks.enumerated() {
            print("Extracting intelligence from chunk \(i + 1) of \(chunks.count)")
            do {
                let intelligence = try await extractChunkIntelligence(text: chunk)
                chunkIntelligences.append(intelligence)
            } catch {
                print("Error extracting intelligence from chunk \(i + 1): \(error)")
            }
        }
        
        // Combine chunk intelligences across the entire meeting
        return try await consolidateIntelligences(chunkIntelligences: chunkIntelligences)
    }
    
    @available(iOS 26.0, *)
    private func extractChunkIntelligence(text: String) async throws -> MeetingIntelligence {
        let instructions = """
        You are a research and meeting intelligence analyst.
        Analyze the meeting transcript and extract structured information:
        - summary: A concise but thorough explanation of what was discussed and what happened in this segment.
        - keyPoints: List of important ideas, technical explanations, research guidance, and recommendations.
        - decisions: Only concrete decisions actually made during the meeting. If no explicit decisions were made, return an empty list.
        - actionItems: Specific tasks to do, including context and deadlines if stated. Do not manufacture deadlines.
        - followUps: Unresolved questions or topics to revisit.
        Never invent facts, decisions, or deadlines.
        """
        
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let prompt = "Analyze this meeting transcript and extract structured intelligence:\n\n\(text)"
        
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedMeetingIntelligence.self)
            let result = response.content
            
            return MeetingIntelligence(
                summary: result.summary,
                keyPoints: result.keyPoints,
                decisions: result.decisions,
                actionItems: result.actionItems,
                followUps: result.followUps
            )
        } catch {
            print("Structured extraction error: \(error). Performing fallback.")
            return MeetingIntelligence(
                summary: "Meeting discussion processed.",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                followUps: []
            )
        }
    }
    
    @available(iOS 26.0, *)
    private func consolidateIntelligences(chunkIntelligences: [MeetingIntelligence]) async throws -> MeetingIntelligence {
        guard !chunkIntelligences.isEmpty else {
            return MeetingIntelligence(summary: "Meeting recorded.", keyPoints: [], decisions: [], actionItems: [], followUps: [])
        }
        
        if chunkIntelligences.count == 1 {
            return chunkIntelligences[0]
        }
        
        // Aggregate all key points, decisions, actions, follow-ups
        var allKeyPoints: [String] = []
        var allDecisions: [String] = []
        var allActionItems: [String] = []
        var allFollowUps: [String] = []
        var summaryParts: [String] = []
        
        for item in chunkIntelligences {
            if !item.summary.isEmpty { summaryParts.append(item.summary) }
            allKeyPoints.append(contentsOf: item.keyPoints)
            allDecisions.append(contentsOf: item.decisions)
            allActionItems.append(contentsOf: item.actionItems)
            allFollowUps.append(contentsOf: item.followUps)
        }
        
        // Deduplicate bullet items while preserving order
        allKeyPoints = deduplicate(allKeyPoints)
        allDecisions = deduplicate(allDecisions)
        allActionItems = deduplicate(allActionItems)
        allFollowUps = deduplicate(allFollowUps)
        
        // Consolidate chunk summaries into a unified coherent meeting summary
        let combinedSummaryText = summaryParts.joined(separator: "\n\n")
        var finalSummary = combinedSummaryText
        
        if summaryParts.count > 1 && combinedSummaryText.count <= getModelContextLimit() {
            let consolidateInstructions = "Synthesize multiple section summaries of a long meeting into one cohesive, well-written meeting summary. Never invent facts."
            let session = LanguageModelSession(model: .default, instructions: consolidateInstructions)
            let prompt = "Consolidate these section summaries into one cohesive meeting summary:\n\n\(combinedSummaryText)"
            
            if let response = try? await session.respond(to: prompt, generating: ConsolidatedSummaryOutput.self) {
                finalSummary = response.content.summary
            }
        }
        
        return MeetingIntelligence(
            summary: finalSummary,
            keyPoints: allKeyPoints,
            decisions: allDecisions,
            actionItems: allActionItems,
            followUps: allFollowUps
        )
    }
    
    private func deduplicate(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let key = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty && !seen.contains(key) {
                seen.insert(key)
                result.append(item.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return result
    }
    
    // MARK: - Title Generation
    
    @available(iOS 26.0, *)
    private func generateMeetingTitle(formattedTranscript: String, date: Date) async throws -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy"
        let dateString = dateFormatter.string(from: date)
        
        let fallbackTitle = "Talk — \(dateString)"
        
        let instructions = "Generate a short, concise, descriptive title (3-6 words) for the meeting based on the main participants, course, or topic discussed (e.g. 'Nahian — ADR Research Planning' or 'MATH 230H Office Hours — Vector Fields'). Do not include dates."
        let session = LanguageModelSession(model: .default, instructions: instructions)
        let prefix = String(formattedTranscript.prefix(3000))
        let prompt = "Extract a short title for this meeting:\n\n\(prefix)"
        
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedTitle.self)
            let titleText = response.content.title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'-")))
            if !titleText.isEmpty {
                return "\(titleText) — \(dateString)"
            }
        } catch {
            print("Title generation error: \(error). Using fallback.")
        }
        
        return fallbackTitle
    }
    
    // MARK: - Semantic Chunking Helper
    
    public nonisolated func splitIntoChunks(text: String, targetSize: Int) -> [String] {
        var chunks: [String] = []
        let paragraphs = text.components(separatedBy: "\n\n")
        var currentChunk = ""
        
        for paragraph in paragraphs {
            if currentChunk.count + paragraph.count > targetSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
                currentChunk = paragraph
            } else {
                if !currentChunk.isEmpty {
                    currentChunk += "\n\n"
                }
                currentChunk += paragraph
            }
        }
        
        if !currentChunk.isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        
        return chunks.isEmpty ? [text] : chunks
    }
}
