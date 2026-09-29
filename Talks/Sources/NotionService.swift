import Foundation

// MARK: - Architectural Invariant: Direct Notion Integration
// 1. Direct API: Communicates directly between iPhone and api.notion.com via HTTPS.
//    Zero intermediate servers or proxy relays.
// 2. Keychain Security: Integration tokens and parent IDs are secured in iOS Keychain.
// 3. Parent-Child Resolution: Automatically creates or caches child 'Talks' page.
// 4. Duplicate Prevention: Queries existing pages by recording ID to guarantee
//    idempotent uploads and zero duplicate Notion pages.

public enum NotionError: LocalizedError {
    case missingCredentials
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case parsingError(String)
    case rateLimited
    
    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "Notion integration token or parent page ID is missing. Please configure them in Settings."
        case .invalidURL:
            return "Invalid Notion API URL."
        case .httpError(let code, let msg):
            return "Notion API error (\(code)): \(msg)"
        case .parsingError(let msg):
            return "Failed to parse Notion response: \(msg)"
        case .rateLimited:
            return "Notion rate limit encountered. Please retry shortly."
        }
    }
}

public actor NotionService {
    public static let shared = NotionService()
    
    private let apiBase = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"
    
    private let session: URLSession
    
    public init(session: URLSession = .shared) {
        self.session = session
    }
    
    // MARK: - Credential Helpers
    
    public nonisolated func getApiKey() -> String? {
        KeychainHelper.get(key: TalksConstants.KeychainKeys.notionApiKey)
    }
    
    public nonisolated func setApiKey(_ key: String) {
        KeychainHelper.save(key: TalksConstants.KeychainKeys.notionApiKey, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    public nonisolated func getParentPageId() -> String? {
        KeychainHelper.get(key: TalksConstants.KeychainKeys.notionParentPageId)
    }
    
    public nonisolated func setParentPageId(_ idOrUrl: String) {
        let cleaned = extractPageId(from: idOrUrl)
        KeychainHelper.save(key: TalksConstants.KeychainKeys.notionParentPageId, value: cleaned)
    }
    
    public nonisolated func getCachedTalksPageId() -> String? {
        KeychainHelper.get(key: TalksConstants.KeychainKeys.notionTalksPageId)
    }
    
    public nonisolated func setCachedTalksPageId(_ id: String) {
        KeychainHelper.save(key: TalksConstants.KeychainKeys.notionTalksPageId, value: id)
    }
    
    /// Parses clean 32-character Notion UUID from a raw string or full Notion page URL.
    public nonisolated func extractPageId(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // If it's a URL like https://www.notion.so/workspace/Page-Name-1234567890abcdef1234567890abcdef?pvs=4
        if let url = URL(string: trimmed), let lastComponent = url.pathComponents.last {
            let parts = lastComponent.components(separatedBy: "-")
            if let lastPart = parts.last, lastPart.count >= 32 {
                return formatUUID(String(lastPart.suffix(32)))
            }
        }
        
        let hexChars = trimmed.replacingOccurrences(of: "-", with: "")
        if hexChars.count == 32 {
            return formatUUID(hexChars)
        }
        return trimmed
    }
    
    private nonisolated func formatUUID(_ hex: String) -> String {
        guard hex.count == 32 else { return hex }
        let p1 = hex.prefix(8)
        let p2 = hex.dropFirst(8).prefix(4)
        let p3 = hex.dropFirst(12).prefix(4)
        let p4 = hex.dropFirst(16).prefix(4)
        let p5 = hex.dropFirst(20)
        return "\(p1)-\(p2)-\(p3)-\(p4)-\(p5)"
    }
    
    private func createRequest(path: String, method: String, token: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: "\(apiBase)\(path)") else {
            throw NotionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    
    // MARK: - Retry & Network Helper
    
    private func sendWithRetry(
        _ request: URLRequest,
        maxRetries: Int = 3
    ) async throws -> (Data, URLResponse) {
        var attempt = 0
        var delay: UInt64 = 1_000_000_000 // 1 second in nanoseconds
        
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    return (data, response)
                }
                
                let isRateLimited = (http.statusCode == 429)
                let isServerError = (500...599).contains(http.statusCode)
                
                if (isRateLimited || isServerError) && attempt <= maxRetries {
                    var waitTimeNanos = delay
                    if let retryAfterStr = http.value(forHTTPHeaderField: "Retry-After"),
                       let retryAfterSec = Double(retryAfterStr), retryAfterSec > 0 {
                        waitTimeNanos = UInt64(retryAfterSec * 1_000_000_000)
                    } else {
                        let jitter = Double.random(in: 0.8...1.2)
                        waitTimeNanos = UInt64(Double(delay) * jitter)
                        delay *= 2
                    }
                    
                    print("Notion API returned HTTP \(http.statusCode). Retrying in \(Double(waitTimeNanos)/1_000_000_000)s (attempt \(attempt)/\(maxRetries))...")
                    try await Task.sleep(nanoseconds: waitTimeNanos)
                    continue
                }
                
                return (data, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt <= maxRetries {
                    let jitter = Double.random(in: 0.8...1.2)
                    let waitTimeNanos = UInt64(Double(delay) * jitter)
                    delay *= 2
                    print("Notion network error: \(error.localizedDescription). Retrying in \(Double(waitTimeNanos)/1_000_000_000)s (attempt \(attempt)/\(maxRetries))...")
                    try await Task.sleep(nanoseconds: waitTimeNanos)
                    continue
                }
                throw error
            }
        }
    }
    
    // MARK: - Verification & Setup
    
    /// Verifies connectivity and ensures the 'Talks' parent page exists.
    public func verifyAndEnsureTalksPage() async throws -> String {
        guard let token = getApiKey(), !token.isEmpty,
              let parentId = getParentPageId(), !parentId.isEmpty else {
            throw NotionError.missingCredentials
        }
        
        // 1. Check if cached Talks page ID is still valid
        if let cachedId = getCachedTalksPageId(), !cachedId.isEmpty {
            if try await checkPageExists(pageId: cachedId, token: token) {
                return cachedId
            }
        }
        
        // 2. Search children of parent page for existing "Talks" page
        if let existingId = try await findChildPage(named: "Talks", under: parentId, token: token) {
            setCachedTalksPageId(existingId)
            return existingId
        }
        
        // 3. Create the 'Talks' parent page under the configured parent page
        let talksPageId = try await createTalksParentPage(under: parentId, token: token)
        setCachedTalksPageId(talksPageId)
        return talksPageId
    }
    
    private func checkPageExists(pageId: String, token: String) async throws -> Bool {
        let request = try createRequest(path: "/pages/\(pageId)", method: "GET", token: token)
        let (_, response) = try await sendWithRetry(request)
        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            return true
        }
        return false
    }
    
    private func findChildPage(named title: String, under parentId: String, token: String) async throws -> String? {
        let request = try createRequest(path: "/blocks/\(parentId)/children?page_size=100", method: "GET", token: token)
        let (data, response) = try await sendWithRetry(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]] {
            for block in results {
                if let type = block["type"] as? String, type == "child_page",
                   let childPage = block["child_page"] as? [String: Any],
                   let pageTitle = childPage["title"] as? String,
                   pageTitle.lowercased() == title.lowercased(),
                   let blockId = block["id"] as? String {
                    return blockId
                }
            }
        }
        return nil
    }
    
    private func createTalksParentPage(under parentId: String, token: String) async throws -> String {
        let body: [String: Any] = [
            "parent": ["page_id": parentId],
            "icon": ["type": "emoji", "emoji": "🎙️"],
            "properties": [
                "title": [
                    "title": [
                        ["text": ["content": "Talks"]]
                    ]
                ]
            ]
        ]
        
        let request = try createRequest(path: "/pages", method: "POST", token: token, body: body)
        let (data, response) = try await sendWithRetry(request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.httpError(statusCode: 0, message: "No response from Notion.")
        }
        
        if http.statusCode == 429 {
            throw NotionError.rateLimited
        }
        
        guard (200...299).contains(http.statusCode) else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NotionError.httpError(statusCode: http.statusCode, message: errorText)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newId = json["id"] as? String else {
            throw NotionError.parsingError("Could not parse new Talks page ID")
        }
        
        return newId
    }
    
    private func getExistingBlockCount(pageId: String, token: String) async throws -> Int {
        var count = 0
        var cursor: String? = nil
        
        repeat {
            var path = "/blocks/\(pageId)/children?page_size=100"
            if let cursor = cursor {
                path += "&start_cursor=\(cursor)"
            }
            let request = try createRequest(path: path, method: "GET", token: token)
            let (data, response) = try await sendWithRetry(request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return count
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return count
            }
            count += results.count
            let hasMore = json["has_more"] as? Bool ?? false
            cursor = hasMore ? (json["next_cursor"] as? String) : nil
        } while cursor != nil
        
        return count
    }
    
    // MARK: - Meeting Upload Pipeline
    
    /// Uploads a meeting to Notion, following the exact hierarchy:
    /// TOP:
    /// 1. AI-Formatted Transcript (FIRST substantive section)
    /// 2. Divider
    /// 3. Summary
    /// 4. Key Points
    /// 5. Decisions
    /// 6. Action Items
    /// 7. Follow-Ups
    /// 8. Divider
    /// 9. Raw Transcript (ABSOLUTE BOTTOM)
    /// BOTTOM
    public func uploadMeeting(
        job: MeetingJob,
        onPageCreated: (@Sendable (String) -> Void)? = nil
    ) async throws -> (pageId: String, pageUrl: String) {
        PipelineLogger.log(stage: "upload started", jobId: job.id, details: "Title: \(job.displayTitle)")
        guard let token = getApiKey(), !token.isEmpty else {
            throw NotionError.missingCredentials
        }
        
        let talksParentId = try await verifyAndEnsureTalksPage()
        
        // 1. Build all block payloads according to the exact spec
        let allBlocks = buildBlocks(for: job)
        
        var targetPageId = job.notionPageId
        var pageUrl = job.notionPageUrl ?? ""
        
        // If a page was already created in a previous attempt, reconcile blocks
        if let existingId = targetPageId {
            if try await checkPageExists(pageId: existingId, token: token) {
                let existingBlockCount = try await getExistingBlockCount(pageId: existingId, token: token)
                if existingBlockCount < allBlocks.count {
                    let missingBlocks = Array(allBlocks.dropFirst(existingBlockCount))
                    try await appendBlocksInBatches(pageId: existingId, blocks: missingBlocks, token: token)
                }
                let finalUrl = pageUrl.isEmpty ? "https://notion.so/\(existingId.replacingOccurrences(of: "-", with: ""))" : pageUrl
                return (existingId, finalUrl)
            } else {
                // Page was deleted or unreachable, reset targetPageId to recreate cleanly
                targetPageId = nil
            }
        }
        
        // 2. If page doesn't exist yet, create it with the first batch of blocks (up to 100)
        let initialBatch = Array(allBlocks.prefix(100))
        let remainingBlocks = Array(allBlocks.dropFirst(100))
        
        let pageTitle = job.displayTitle
        let createBody: [String: Any] = [
            "parent": ["page_id": talksParentId],
            "icon": ["type": "emoji", "emoji": "📝"],
            "properties": [
                "title": [
                    "title": [
                        ["text": ["content": pageTitle]]
                    ]
                ]
            ],
            "children": initialBatch
        ]
        
        let request = try createRequest(path: "/pages", method: "POST", token: token, body: createBody)
        let (data, response) = try await sendWithRetry(request)
        guard let http = response as? HTTPURLResponse else {
            throw NotionError.httpError(statusCode: 0, message: "No response from Notion.")
        }
        if http.statusCode == 429 { throw NotionError.rateLimited }
        guard (200...299).contains(http.statusCode) else {
            let errText = String(data: data, encoding: .utf8) ?? ""
            throw NotionError.httpError(statusCode: http.statusCode, message: errText)
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newId = json["id"] as? String else {
            throw NotionError.parsingError("Unable to parse created meeting page ID.")
        }
        
        targetPageId = newId
        pageUrl = json["url"] as? String ?? "https://notion.so/\(newId.replacingOccurrences(of: "-", with: ""))"
        
        // Persist page ID immediately upon creation for idempotency
        onPageCreated?(newId)
        
        // 3. Append remaining blocks in batches of 100 (handling long meetings safely)
        if !remainingBlocks.isEmpty {
            try await appendBlocksInBatches(pageId: newId, blocks: remainingBlocks, token: token)
        }
        
        PipelineLogger.log(stage: "upload completed", jobId: job.id, details: "URL: \(pageUrl)")
        return (newId, pageUrl)
    }
    
    private func appendBlocksInBatches(pageId: String, blocks: [[String: Any]], token: String) async throws {
        let batchSize = 100
        var startIndex = 0
        
        while startIndex < blocks.count {
            let endIndex = min(startIndex + batchSize, blocks.count)
            let batch = Array(blocks[startIndex..<endIndex])
            
            let body: [String: Any] = ["children": batch]
            let request = try createRequest(path: "/blocks/\(pageId)/children", method: "PATCH", token: token, body: body)
            
            let (data, response) = try await sendWithRetry(request)
            guard let http = response as? HTTPURLResponse else {
                throw NotionError.httpError(statusCode: 0, message: "No response from Notion while appending blocks.")
            }
            if http.statusCode == 429 { throw NotionError.rateLimited }
            guard (200...299).contains(http.statusCode) else {
                let err = String(data: data, encoding: .utf8) ?? ""
                throw NotionError.httpError(statusCode: http.statusCode, message: err)
            }
            
            startIndex = endIndex
        }
    }
    
    // MARK: - Block Construction
    
    public nonisolated func buildBlocks(for job: MeetingJob) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        
        // 1. AI-Formatted Transcript (FIRST substantive content)
        blocks.append(heading1Block("AI-Formatted Transcript"))
        
        let formattedText = job.aiFormattedTranscript ?? "No formatted transcript available."
        let formattedParagraphs = formattedText.components(separatedBy: "\n\n")
        for para in formattedParagraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            if trimmed.hasPrefix("### ") {
                blocks.append(heading3Block(String(trimmed.dropFirst(4))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(heading2Block(String(trimmed.dropFirst(3))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(heading2Block(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                blocks.append(bulletBlock(String(trimmed.dropFirst(2))))
            } else {
                for chunk in splitIntoRichTextChunks(trimmed) {
                    blocks.append(paragraphBlock(chunk))
                }
            }
        }
        
        // Divider
        blocks.append(dividerBlock())
        
        // 2. Summary
        blocks.append(heading1Block("Summary"))
        let summaryText = job.intelligence?.summary ?? "No summary available."
        for chunk in splitIntoRichTextChunks(summaryText) {
            blocks.append(paragraphBlock(chunk))
        }
        
        // 3. Key Points
        blocks.append(heading1Block("Key Points"))
        let keyPoints = job.intelligence?.keyPoints ?? []
        if keyPoints.isEmpty {
            blocks.append(paragraphBlock("None recorded."))
        } else {
            for point in keyPoints {
                blocks.append(bulletBlock(point))
            }
        }
        
        // 4. Decisions
        blocks.append(heading1Block("Decisions"))
        let decisions = job.intelligence?.decisions ?? []
        if decisions.isEmpty {
            blocks.append(paragraphBlock("No explicit decisions were made."))
        } else {
            for dec in decisions {
                blocks.append(bulletBlock(dec))
            }
        }
        
        // 5. Action Items
        blocks.append(heading1Block("Action Items"))
        let actionItems = job.intelligence?.actionItems ?? []
        if actionItems.isEmpty {
            blocks.append(paragraphBlock("No action items recorded."))
        } else {
            for action in actionItems {
                blocks.append(todoBlock(action, checked: false))
            }
        }
        
        // 6. Follow-Ups
        blocks.append(heading1Block("Follow-Ups"))
        let followUps = job.intelligence?.followUps ?? []
        if followUps.isEmpty {
            blocks.append(paragraphBlock("None recorded."))
        } else {
            for item in followUps {
                blocks.append(bulletBlock(item))
            }
        }
        
        // Strong separator
        blocks.append(dividerBlock())
        
        // 7. Raw Transcript (ABSOLUTE BOTTOM - Untouched source-of-truth)
        blocks.append(heading1Block("Raw Transcript"))
        let raw = job.rawTranscript ?? "No raw transcript recorded."
        let rawParagraphs = raw.components(separatedBy: "\n\n")
        for para in rawParagraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for chunk in splitIntoRichTextChunks(trimmed) {
                blocks.append(paragraphBlock(chunk))
            }
        }
        
        return blocks
    }
    
    // MARK: - Block Builders (ensuring <= 2000 chars per text element)
    
    public nonisolated func heading1Block(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_1",
            "heading_1": [
                "rich_text": [
                    ["type": "text", "text": ["content": String(text.prefix(2000))]]
                ]
            ]
        ]
    }
    
    public nonisolated func heading2Block(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_2",
            "heading_2": [
                "rich_text": [
                    ["type": "text", "text": ["content": String(text.prefix(2000))]]
                ]
            ]
        ]
    }
    
    public nonisolated func heading3Block(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "heading_3",
            "heading_3": [
                "rich_text": [
                    ["type": "text", "text": ["content": String(text.prefix(2000))]]
                ]
            ]
        ]
    }
    
    public nonisolated func paragraphBlock(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "paragraph",
            "paragraph": [
                "rich_text": [
                    ["type": "text", "text": ["content": String(text.prefix(2000))]]
                ]
            ]
        ]
    }
    
    public nonisolated func bulletBlock(_ text: String) -> [String: Any] {
        [
            "object": "block",
            "type": "bulleted_list_item",
            "bulleted_list_item": [
                "rich_text": [
                    ["type": "text", "text": ["content": String(text.prefix(2000))]]
                ]
            ]
        ]
    }
    
    public nonisolated func todoBlock(_ text: String, checked: Bool) -> [String: Any] {
        [
            "object": "block",
            "type": "to_do",
            "to_do": [
                "rich_text": [
                    ["type": "text", "text": ["content": String(text.prefix(2000))]]
                ],
                "checked": checked
            ]
        ]
    }
    
    public nonisolated func dividerBlock() -> [String: Any] {
        [
            "object": "block",
            "type": "divider",
            "divider": [:]
        ]
    }
    
    public nonisolated func splitIntoRichTextChunks(_ text: String) -> [String] {
        let limit = 1950 // keep safely below Notion's 2000 character rich_text limit
        guard text.count > limit else { return [text] }
        
        var chunks: [String] = []
        var remaining = text
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(limit))
            chunks.append(chunk)
            remaining = String(remaining.dropFirst(limit))
        }
        return chunks
    }
}
