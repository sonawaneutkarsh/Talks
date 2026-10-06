import XCTest
import WatchConnectivity
@testable import Talks

/// Watch -> iPhone ingestion, ACK-gated deletion on the Watch, structured logging, and launch-time UI construction.
///
/// Physical-device limit: the simulator cannot pair an Apple Watch, so `WCSession.transferFile` /
/// `transferUserInfo` delivery itself is not exercised here. These tests cover the code on both
/// sides of that boundary (enqueue-then-ACK on the phone, ACK handling and file deletion on the Watch).
final class ConnectivityAndLaunchTests: XCTestCase {

    // MARK: - iPhone side: receive, enqueue, then ACK

    @MainActor
    func testReceivedRecordingIsEnqueuedBeforeAckIsAttempted() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let phone = PhoneConnectivityManager(queueManager: queue, activateSession: false)
        let recordingId = UUID()

        phone.handleReceivedRecording(id: recordingId, createdAt: Date(), duration: 120, relativeAudioPath: "\(recordingId.uuidString).m4a")

        let job = try XCTUnwrap(queue.jobs.first { $0.id == recordingId })
        XCTAssertEqual(job.duration, 120)
        XCTAssertEqual(job.localAudioRelativePath, "\(recordingId.uuidString).m4a")
        XCTAssertEqual(job.status, .received)
        XCTAssertTrue(phone.lastEnqueueSuccess)
        XCTAssertEqual(phone.lastReceivedRecordingId, recordingId)

        // diagnosticLogs is newest-first: the ACK attempt must come after the successful enqueue.
        let logs = phone.diagnosticLogs
        let enqueueIndex = try XCTUnwrap(logs.firstIndex { $0.contains("enqueueReceivedRecording SUCCEEDED") })
        let ackIndex = try XCTUnwrap(logs.firstIndex { $0.contains("sendAck skipped: session not activated") })
        XCTAssertLessThan(ackIndex, enqueueIndex, "The ACK may only be sent after the recording is persisted in the queue")

        await queue.waitUntilIdle()
    }

    @MainActor
    func testDuplicateDeliveryOfSameRecordingDoesNotCreateSecondJob() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let phone = PhoneConnectivityManager(queueManager: queue, activateSession: false)
        let recordingId = UUID()

        phone.handleReceivedRecording(id: recordingId, createdAt: Date(), duration: 30, relativeAudioPath: "a.m4a")
        phone.handleReceivedRecording(id: recordingId, createdAt: Date(), duration: 31, relativeAudioPath: "a.m4a")

        XCTAssertEqual(queue.jobs.filter { $0.id == recordingId }.count, 1, "WatchConnectivity may redeliver; the job is keyed by recording ID")
        XCTAssertEqual(queue.jobs.first?.duration, 31)
        await queue.waitUntilIdle()
    }

    @MainActor
    func testPingTimeoutDoesNotBlockTransferFileWorkflow() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let phone = PhoneConnectivityManager(queueManager: queue, activateSession: false)
        let recordingId = UUID()
        let audioName = "\(recordingId.uuidString).m4a"
        try SyntheticPipelineRunner.createTestAudioFile(at: queue.recordingsDirectory.appendingPathComponent(audioName), durationSeconds: 1.0)

        phone.logEvent("Ping Watch error: The operation couldn’t be completed. (WCErrorDomain error 7012 - Transfer timed out)")
        phone.handleReceivedRecording(id: recordingId, createdAt: Date(), duration: 1.0, relativeAudioPath: audioName)

        XCTAssertNotNil(queue.jobs.first { $0.id == recordingId }, "A received file is enqueued regardless of an earlier ping timeout")
        XCTAssertTrue(phone.lastEnqueueSuccess)
        await queue.waitUntilIdle()
    }

    @MainActor
    func testPingFailureDoesNotAlterQueuedRecordingState() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let phone = PhoneConnectivityManager(queueManager: queue, activateSession: false)
        let job = MeetingJob(id: UUID(), duration: 15, localAudioRelativePath: "test.m4a", status: .received)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        phone.logEvent("Ping ERROR from Watch: WCErrorCodeTransferTimedOut")

        let current = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(current.status, .received)
        XCTAssertEqual(current.localAudioRelativePath, "test.m4a")
        XCTAssertNil(current.errorMessage)
        XCTAssertTrue(phone.diagnosticLogs.first?.contains("WCErrorCodeTransferTimedOut") == true)
    }

    @MainActor
    func testIncomingPingIsAnsweredWithoutTouchingTheQueue() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let phone = PhoneConnectivityManager(queueManager: queue, activateSession: false)
        let replied = expectation(description: "Ping reply handler invoked")
        let reply = ThreadSafeBox<[String: String]>([:])

        phone.session(WCSession.default, didReceiveMessage: ["type": "ping", "timestamp": Date().timeIntervalSince1970]) { response in
            reply.set(response.compactMapValues { $0 as? String })
            replied.fulfill()
        }
        await fulfillment(of: [replied], timeout: 2.0)

        XCTAssertEqual(reply.get()["response"], "pong")
        XCTAssertEqual(reply.get()["device"], "iPhone")
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    @MainActor
    func testAckIsSkippedWhenSessionIsNotActivated() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let phone = PhoneConnectivityManager(queueManager: makeQueue(in: dir), activateSession: false)

        phone.sendAckToWatch(recordingId: UUID())

        XCTAssertEqual(phone.diagnosticLogs.first?.hasSuffix("sendAck skipped: session not activated"), true)
    }

    // MARK: - Watch side: ACK-gated deletion (WatchTransferLedger is shared with the watchOS target)

    /// Replaces a placeholder that tested an inline `if recordingId == recordingId` instead of production code.
    func testWatchRecordingDeletionOnlyAfterACK() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let recordings = dir.appendingPathComponent("WatchRecordings", isDirectory: true)
        let registry = dir.appendingPathComponent("watch_transfers.json")

        let idA = UUID()
        let idB = UUID()
        let fileA = writeDummyAudio(named: "\(idA.uuidString).m4a", in: recordings)
        let fileB = writeDummyAudio(named: "\(idB.uuidString).m4a", in: recordings)

        var ledger = WatchTransferLedger(registryURL: registry, recordingsDirectory: recordings)
        ledger.track(WatchTransferRecord(id: idA, createdAt: Date(), duration: 30, fileRelativePath: fileA.lastPathComponent))
        ledger.track(WatchTransferRecord(id: idB, createdAt: Date(), duration: 45, fileRelativePath: fileB.lastPathComponent))

        XCTAssertEqual(ledger.acknowledge(recordingId: UUID()), .untracked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileA.path), "An unrelated ACK must not delete anything")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path))

        // Simulate a Watch app relaunch between transfer and ACK.
        var relaunched = WatchTransferLedger(registryURL: registry, recordingsDirectory: recordings)
        XCTAssertEqual(Set(relaunched.pendingRecords.map(\.id)), [idA, idB], "Pending transfers survive relaunch")

        XCTAssertEqual(relaunched.acknowledge(recordingId: idA), .acknowledgedAndDeleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileA.path), "The matching ACK deletes that recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileB.path), "Other recordings stay until their own ACK")
        XCTAssertEqual(relaunched.pendingRecords.map(\.id), [idB])

        XCTAssertEqual(relaunched.acknowledge(recordingId: idA), .acknowledgedFileAlreadyMissing, "A duplicate ACK is harmless")

        let afterAck = WatchTransferLedger(registryURL: registry, recordingsDirectory: recordings)
        XCTAssertEqual(afterAck.records.first { $0.id == idA }?.isAcknowledgedByPhone, true, "The ACK state is persisted")
        XCTAssertEqual(afterAck.pendingRecords.map(\.id), [idB])
    }

    // MARK: - Structured logging

    /// Replaces a placeholder that called PipelineLogger.log and asserted `true`.
    func testPipelineLoggerOutputStructuredFormat() {
        let jobId = UUID(uuidString: "12345678-ABCD-4321-ABCD-1234567890AB")!
        let epoch = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            PipelineLogger.formatLine(timestamp: epoch, stage: "upload started", jobId: jobId, details: "Title: Weekly sync",
                                      isMainThread: true, threadDescription: "main"),
            "[1970-01-01T00:00:00.000Z] [PIPELINE] [upload started] [job: 12345678] [isMain: true] [main] | Title: Weekly sync"
        )
        XCTAssertEqual(
            PipelineLogger.formatLine(timestamp: epoch, stage: "boot", jobId: nil, details: "",
                                      isMainThread: false, threadDescription: "worker"),
            "[1970-01-01T00:00:00.000Z] [PIPELINE] [boot] [job: none] [isMain: false] [worker]"
        )

        // The listener receives every event exactly once, including concurrent logging from many threads.
        let received = ThreadSafeBox<[String]>([])
        PipelineLogger.logListener = { stage, id, _ in
            if id == jobId { received.update { $0.append(stage) } }
        }
        defer { PipelineLogger.logListener = nil }
        DispatchQueue.concurrentPerform(iterations: 50) { i in
            PipelineLogger.log(stage: "stage-\(i)", jobId: jobId, details: "concurrent")
        }
        XCTAssertEqual(received.get().count, 50)
        XCTAssertEqual(Set(received.get()), Set((0..<50).map { "stage-\($0)" }))
    }

    // MARK: - Launch-time UI construction

    @MainActor
    func testAppLaunchWithWCSessionStuckConstructsRootUI() {
        let logs = LogRecorder()
        defer { logs.stop() }

        _ = ContentView().body

        XCTAssertTrue(logs.contains("[LAUNCH] ContentView.init"))
        XCTAssertTrue(logs.contains("[LAUNCH] ContentView.body evaluated"))
    }

    @MainActor
    func testRootUIRendersBeforeWCSessionCallbacks() {
        let logs = LogRecorder()
        defer { logs.stop() }

        _ = ContentView().body
        let entriesBeforeCallback = logs.entries
        XCTAssertTrue(entriesBeforeCallback.contains("[LAUNCH] ContentView.body evaluated"))

        // A late WCSession activation callback must not be required for the root UI.
        PhoneConnectivityManager.shared.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)
        XCTAssertEqual(Array(logs.entries.prefix(entriesBeforeCallback.count)), entriesBeforeCallback)
    }

    @MainActor
    func testRootAndDetailViewsPreserveQueueState() {
        let queueManager = JobQueueManager.shared
        let initialProcessingState = queueManager.isProcessing
        let initialJobIds = queueManager.jobs.map(\.id)

        _ = ContentView().body
        _ = SettingsView().body
        _ = TalkDetailView(job: MeetingJob(id: UUID(), duration: 120, localAudioRelativePath: "sample.m4a", status: .completed)).body

        XCTAssertEqual(queueManager.isProcessing, initialProcessingState, "Building views must not start or stop processing")
        XCTAssertEqual(queueManager.jobs.map(\.id), initialJobIds, "Building views must not mutate the queue")
    }

    func testMeetingJobPersistsNoPingState() throws {
        let job = MeetingJob(id: UUID(), duration: 60, localAudioRelativePath: "rec.m4a", status: .completed)
        let mirror = Mirror(reflecting: job)
        XCTAssertFalse(mirror.children.contains { $0.label?.lowercased().contains("ping") ?? false },
                       "Ping diagnostics are transient and must not be part of the persisted job model")

        let json = try XCTUnwrap(String(data: JSONEncoder().encode(job), encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("ping"))
    }
}
