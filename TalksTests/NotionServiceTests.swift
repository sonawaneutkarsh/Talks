import XCTest
@testable import Talks

final class NotionServiceTests: XCTestCase {

    private let talksPageId = "87654321-4321-4321-4321-cba987654321"

    private func makeConfiguredService() -> NotionService {
        let service = NotionService(session: makeMockSession())
        service.setApiKey("secret_test_token")
        service.setParentPageId("12345678-1234-1234-1234-123456789abc")
        service.setCachedTalksPageId(talksPageId)
        return service
    }

    private func makeJob(notionPageId: String? = nil) -> MeetingJob {
        MeetingJob(
            id: UUID(),
            createdAt: Date(),
            duration: 60,
            rawTranscript: "Test raw transcript",
            aiFormattedTranscript: "Test formatted",
            intelligence: MeetingIntelligence(summary: "S", keyPoints: [], decisions: [], actionItems: [], followUps: []),
            title: "Test Meeting",
            notionPageId: notionPageId,
            status: .waitingForNotion
        )
    }

    private func childCount(inPatchBody body: Data?) -> Int {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let children = json["children"] as? [[String: Any]] else { return -1 }
        return children.count
    }

    // MARK: - Page layout

    func testNotionExactBlockHierarchyOrdering() {
        let job = MeetingJob(
            id: UUID(),
            createdAt: Date(),
            duration: 1800,
            rawTranscript: "Professor: Make sure to finalize the benchmark script.\n\nStudent: Understood, will have it done by Friday.",
            aiFormattedTranscript: "### Benchmark Script Finalization\n\n- Professor and student discussed the milestone timeline.",
            intelligence: MeetingIntelligence(
                summary: "Research check-in regarding anomaly detection benchmark completion.",
                keyPoints: ["Compare reconstruction error against baseline."],
                decisions: ["Freeze model weights before evaluation."],
                actionItems: ["Finalize script by Friday."],
                followUps: ["Schedule follow-up meeting on Monday."]
            ),
            title: "Advisor — ADR Planning — Sep 28, 2026",
            status: .waitingForNotion
        )

        let blocks = NotionService.shared.buildBlocks(for: job)
        XCTAssertFalse(blocks.isEmpty)

        let heading1Titles: [String] = blocks.compactMap { block in
            guard (block["type"] as? String) == "heading_1",
                  let h1 = block["heading_1"] as? [String: Any],
                  let richText = h1["rich_text"] as? [[String: Any]],
                  let textObj = richText.first?["text"] as? [String: Any] else { return nil }
            return textObj["content"] as? String
        }
        XCTAssertEqual(heading1Titles, [
            "AI-Formatted Transcript",
            "Summary",
            "Key Points",
            "Decisions",
            "Action Items",
            "Follow-Ups",
            "Raw Transcript"
        ])

        XCTAssertEqual(blocks.filter { ($0["type"] as? String) == "divider" }.count, 2)
        XCTAssertEqual(blocks.filter { ($0["type"] as? String) == "to_do" }.count, 1, "Action items become Notion to-do blocks")

        guard let rawHeadingIndex = blocks.firstIndex(where: { block in
            (block["type"] as? String) == "heading_1" &&
            (((block["heading_1"] as? [String: Any])?["rich_text"] as? [[String: Any]])?.first?["text"] as? [String: Any])?["content"] as? String == "Raw Transcript"
        }) else {
            return XCTFail("Raw Transcript heading must exist")
        }
        let trailingBlocks = Array(blocks[(rawHeadingIndex + 1)...])
        XCTAssertEqual(trailingBlocks.count, 2, "One paragraph per raw transcript paragraph")
        XCTAssertTrue(trailingBlocks.allSatisfy { ($0["type"] as? String) == "paragraph" }, "Nothing but raw transcript follows the Raw Transcript heading")
    }

    func testMultiChunkNotionUploadBlockSplitting() {
        let longParagraph = String(repeating: "Discussion content for long meeting note. ", count: 100) // ~4,200 chars
        XCTAssertGreaterThan(longParagraph.count, 2000)

        let job = MeetingJob(
            id: UUID(),
            createdAt: Date(),
            duration: 1800,
            rawTranscript: longParagraph,
            aiFormattedTranscript: longParagraph,
            intelligence: MeetingIntelligence(summary: "S"),
            title: "Long Meeting",
            status: .waitingForNotion
        )

        let blocks = NotionService.shared.buildBlocks(for: job)
        var paragraphText = ""
        for block in blocks {
            guard let type = block["type"] as? String,
                  let contentMap = block[type] as? [String: Any],
                  let richText = contentMap["rich_text"] as? [[String: Any]] else { continue }
            for item in richText {
                if let text = (item["text"] as? [String: Any])?["content"] as? String {
                    XCTAssertLessThanOrEqual(text.count, 2000, "Notion rich_text content must never exceed 2000 chars")
                    if type == "paragraph" { paragraphText += text }
                }
            }
        }
        // The formatted and raw copies of the paragraph are both preserved in full after splitting.
        let expected = longParagraph.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(paragraphText.components(separatedBy: expected).count - 1, 2, "Splitting must not drop characters")
    }

    func testNotionPageIdExtractionEdgeCases() {
        let service = NotionService.shared
        let expected = "12345678-abcd-1234-abcd-123456789abc"
        XCTAssertEqual(service.extractPageId(from: "12345678-abcd-1234-abcd-123456789abc"), expected)
        XCTAssertEqual(service.extractPageId(from: "12345678abcd1234abcd123456789abc"), expected)
        XCTAssertEqual(service.extractPageId(from: "https://www.notion.so/workspace/Research-Notes-12345678abcd1234abcd123456789abc"), expected)
        XCTAssertEqual(service.extractPageId(from: "https://www.notion.so/workspace/Research-Notes-12345678abcd1234abcd123456789abc?pvs=4"), expected)
        XCTAssertEqual(service.extractPageId(from: "   12345678abcd1234abcd123456789abc \n"), expected)
    }

    // MARK: - Credentials

    func testNotionMissingCredentialsHandling() async {
        let originalKey = NotionService.shared.getApiKey()
        let originalParent = NotionService.shared.getParentPageId()
        defer {
            if let key = originalKey { NotionService.shared.setApiKey(key) }
            if let parent = originalParent { NotionService.shared.setParentPageId(parent) }
        }

        NotionService.shared.setApiKey("")
        NotionService.shared.setParentPageId("")

        do {
            _ = try await NotionService.shared.uploadMeeting(job: makeJob())
            XCTFail("uploadMeeting must throw NotionError.missingCredentials when keys are absent")
        } catch NotionError.missingCredentials {
            // Expected
        } catch {
            XCTFail("Expected NotionError.missingCredentials, received: \(error)")
        }
    }

    // MARK: - Network behaviour

    func testNotionNetworkRetryAndRateLimitHandling() async throws {
        let service = makeConfiguredService()

        MockURLProtocol.setHandlers([
            notionResponse(200, json: ["id": talksPageId]),                                        // cached Talks page exists
            notionResponse(429, json: ["message": "rate_limited"], headers: ["Retry-After": "0.01"]), // POST /pages rate limited
            notionResponse(200, json: ["id": "new-page-id-999", "url": "https://notion.so/newpage"]) // POST /pages retry succeeds
        ])

        let callbackBox = ThreadSafeBox<String?>(nil)
        let result = try await service.uploadMeeting(job: makeJob(), onPageCreated: { callbackBox.set($0) })

        XCTAssertEqual(result.pageId, "new-page-id-999")
        XCTAssertEqual(result.pageUrl, "https://notion.so/newpage")
        XCTAssertEqual(callbackBox.get(), "new-page-id-999", "onPageCreated must receive the new page ID so it can be persisted")
        XCTAssertEqual(MockURLProtocol.recordedRequests.map(\.method), ["GET", "POST", "POST"], "429 must be retried exactly once here")
    }

    func testNotionUploadBlockReconciliationAndIdempotency() async throws {
        let service = makeConfiguredService()
        let existingPageId = "existing-page-id-555"
        let job = makeJob(notionPageId: existingPageId)
        let totalCount = service.buildBlocks(for: job).count

        MockURLProtocol.setHandlers([
            notionResponse(200, json: ["id": talksPageId]),
            notionResponse(200, json: ["id": existingPageId]),
            notionResponse(200, json: [
                "object": "list",
                "results": Array(repeating: ["id": "block-id"], count: totalCount),
                "has_more": false
            ])
        ])

        let (pageId, _) = try await service.uploadMeeting(job: job)
        XCTAssertEqual(pageId, existingPageId, "Retry must reuse the persisted page instead of creating a new one")
        let methods = MockURLProtocol.recordedRequests.map(\.method)
        XCTAssertEqual(methods, ["GET", "GET", "GET"])
        XCTAssertFalse(methods.contains("POST"), "No new page may be created")
        XCTAssertFalse(methods.contains("PATCH"), "All blocks already exist, so nothing may be appended")
    }

    func testRetryAppendsOnlyTheMissingBlocks() async throws {
        let service = makeConfiguredService()
        let existingPageId = "existing-page-id-777"
        let job = makeJob(notionPageId: existingPageId)
        let totalCount = service.buildBlocks(for: job).count
        let alreadyUploaded = totalCount - 3

        MockURLProtocol.setHandlers([
            notionResponse(200, json: ["id": talksPageId]),
            notionResponse(200, json: ["id": existingPageId]),
            notionResponse(200, json: [
                "object": "list",
                "results": Array(repeating: ["id": "block-id"], count: alreadyUploaded),
                "has_more": false
            ]),
            notionResponse(200, json: ["object": "list", "results": []])
        ])

        _ = try await service.uploadMeeting(job: job)

        let requests = MockURLProtocol.recordedRequests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "GET", "PATCH"])
        XCTAssertEqual(childCount(inPatchBody: requests.last?.body), 3, "Only the 3 blocks that are not on the page yet may be appended")
    }

    /// Regression: getExistingBlockCount used to return the partial count when a later page of
    /// children failed, so the caller appended blocks that already existed (duplicate content).
    func testBlockCountFailureOnLaterPageThrowsAndAppendsNothing() async {
        let service = makeConfiguredService()
        let existingPageId = "existing-page-id-888"
        let job = makeJob(notionPageId: existingPageId)

        MockURLProtocol.setHandlers([
            notionResponse(200, json: ["id": talksPageId]),
            notionResponse(200, json: ["id": existingPageId]),
            notionResponse(200, json: [
                "object": "list",
                "results": Array(repeating: ["id": "block-id"], count: 5),
                "has_more": true,
                "next_cursor": "cursor-2"
            ]),
            notionResponse(404, json: ["message": "Could not find block"])
        ])

        do {
            _ = try await service.uploadMeeting(job: job)
            XCTFail("A failed block count must abort the upload")
        } catch NotionError.httpError(let statusCode, _) {
            XCTAssertEqual(statusCode, 404)
        } catch {
            XCTFail("Expected NotionError.httpError, received: \(error)")
        }

        let requests = MockURLProtocol.recordedRequests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests[3].url.contains("start_cursor=cursor-2"), "Second page must be requested with the cursor")
        XCTAssertFalse(requests.map(\.method).contains("PATCH"), "No blocks may be appended after a partial count")
    }

    func testBlockCountUnparseableResponseThrowsAndAppendsNothing() async {
        let service = makeConfiguredService()
        let existingPageId = "existing-page-id-999"
        let job = makeJob(notionPageId: existingPageId)

        MockURLProtocol.setHandlers([
            notionResponse(200, json: ["id": talksPageId]),
            notionResponse(200, json: ["id": existingPageId]),
            notionRawResponse(200, body: "<html>gateway hiccup</html>")
        ])

        do {
            _ = try await service.uploadMeeting(job: job)
            XCTFail("An unreadable block list must abort the upload")
        } catch NotionError.parsingError {
            // Expected
        } catch {
            XCTFail("Expected NotionError.parsingError, received: \(error)")
        }
        XCTAssertFalse(MockURLProtocol.recordedRequests.map(\.method).contains("PATCH"))
    }
}
