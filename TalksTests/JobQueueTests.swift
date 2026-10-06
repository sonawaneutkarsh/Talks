import XCTest
import UIKit
@testable import Talks

/// JobQueueManager tests. Every test uses its own temporary storage directory and fake pipeline
/// stages, so nothing depends on JobQueueManager.shared, the app's Documents folder, or real
/// Speech / Apple Intelligence / Notion services.
final class JobQueueTests: XCTestCase {

    // MARK: - Persistence & relaunch

    @MainActor
    func testQueueSurvivesRelaunchAndResumesPendingWork() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }

        let completed = MeetingJob(id: UUID(), createdAt: Date(), duration: 45, rawTranscript: "Transcript 1", status: .completed)
        let pending = MeetingJob(id: UUID(), createdAt: Date().addingTimeInterval(-3600), duration: 60,
                                 rawTranscript: "Transcript 2", aiFormattedTranscript: "Formatted 2", status: .uploadingToNotion)

        let first = makeQueue(in: dir)
        first.addSyntheticMeeting(job: pending, startProcessing: false)
        first.addSyntheticMeeting(job: completed, startProcessing: false)

        // A fresh manager on the same directory is what the app sees after being terminated.
        let relaunched = makeQueue(in: dir)
        XCTAssertEqual(relaunched.jobs.map(\.id), [completed.id, pending.id], "Jobs reload newest first")
        XCTAssertEqual(relaunched.jobs[0].status, .completed)
        XCTAssertEqual(relaunched.jobs[1].status, .waitingForNotion, "An interrupted upload resumes idempotently from .waitingForNotion")
        XCTAssertFalse(relaunched.jobs[1].status.isTerminal)
    }

    /// Replaces a placeholder test that decoded garbage and asserted on a local empty array.
    @MainActor
    func testRelaunchWithCorruptQueueJsonRecoversSafelyWithoutCrashing() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }

        let garbage = Data("INVALID_JSON_CORRUPTED_BYTES {{{ [[[".utf8)
        try garbage.write(to: dir.appendingPathComponent("queue.json"))

        let queue = makeQueue(in: dir)
        XCTAssertTrue(queue.jobs.isEmpty, "A corrupt queue file must load as an empty queue instead of crashing")

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("queue.corrupt-") }
        XCTAssertEqual(backups.count, 1, "The unreadable file is kept for diagnosis, not silently overwritten")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backups[0])), garbage)

        // The queue keeps working and persisting after recovery.
        queue.addSyntheticMeeting(job: MeetingJob(id: UUID(), status: .completed), startProcessing: false)
        XCTAssertEqual(makeQueue(in: dir).jobs.count, 1)
    }

    func testRelaunchWithJobInTranscribingResetsToReceivedIfAudioExists() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let audioFilename = "relaunch_transcribing.m4a"
        try SyntheticPipelineRunner.createTestAudioFile(at: dir.appendingPathComponent(audioFilename), durationSeconds: 2.0)

        let job = MeetingJob(id: UUID(), createdAt: Date(), duration: 120, localAudioRelativePath: audioFilename, status: .transcribing)
        let reconciled = JobQueueManager.reconcileInterruptedJobs([job], recordingsDirectory: dir)
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled[0].status, .received)
        XCTAssertNil(reconciled[0].errorMessage)
    }

    func testRelaunchWithJobInFormattingResetsToWaitingForAIIfTranscriptExists() {
        let job = MeetingJob(id: UUID(), createdAt: Date(), duration: 120,
                             rawTranscript: "Professor: Let's finalize the experiment results.", status: .formatting)
        let reconciled = JobQueueManager.reconcileInterruptedJobs([job], recordingsDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(reconciled[0].status, .waitingForAI)
        XCTAssertNil(reconciled[0].errorMessage)
    }

    func testRelaunchWithJobInUploadingToNotionResetsToWaitingForNotionIfFormattedContentExists() {
        let job = MeetingJob(id: UUID(), createdAt: Date(), duration: 120,
                             rawTranscript: "Professor: Let's finalize the experiment results.",
                             aiFormattedTranscript: "### Experiment Results\n- Finalized.", status: .uploadingToNotion)
        let reconciled = JobQueueManager.reconcileInterruptedJobs([job], recordingsDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(reconciled[0].status, .waitingForNotion)
        XCTAssertNil(reconciled[0].errorMessage)
    }

    func testRelaunchWithMissingAudioFileMarksJobFailedWithoutLooping() {
        let job = MeetingJob(id: UUID(), createdAt: Date(), duration: 60,
                             localAudioRelativePath: "missing_file_\(UUID().uuidString).m4a", status: .transcribing)
        let reconciled = JobQueueManager.reconcileInterruptedJobs([job], recordingsDirectory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(reconciled[0].status, .failed)
        XCTAssertTrue(reconciled[0].errorMessage?.contains("missing") == true, "Actionable error message must be set")
    }

    func testRelaunchWithEmptyQueueCleanState() {
        XCTAssertTrue(JobQueueManager.reconcileInterruptedJobs([], recordingsDirectory: FileManager.default.temporaryDirectory).isEmpty)
    }

    func testReconcilingManyFinishedJobsLeavesThemUntouched() {
        let jobs = (1...100).map { _ in MeetingJob(id: UUID(), createdAt: Date(), duration: 60, status: .completed) }
        let start = Date()
        let reconciled = JobQueueManager.reconcileInterruptedJobs(jobs, recordingsDirectory: FileManager.default.temporaryDirectory)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(reconciled.map(\.id), jobs.map(\.id))
        XCTAssertTrue(reconciled.allSatisfy { $0.status == .completed })
        XCTAssertLessThan(elapsed, 1.0, "Launch-time reconciliation of 100 jobs must stay well under a second (was \(elapsed)s)")
    }

    // MARK: - Processing loop

    @MainActor
    func testPipelineNeverModifiesRawTranscript() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }

        let uploadedRaw = ThreadSafeBox<String?>(nil)
        var deps = QueueDependencies.fake()
        deps.structureTranscript = { raw, _, _ in
            (raw.replacingOccurrences(of: "um, ", with: ""), MeetingIntelligence(summary: "Discussion on ADR research benchmarks."), "ADR Planning")
        }
        deps.uploadToNotion = { job, onPageCreated in
            uploadedRaw.set(job.rawTranscript)
            onPageCreated("page-1")
            return ("page-1", "https://notion.so/page1")
        }

        let sampleRaw = SyntheticPipelineRunner.sampleRawTranscript
        XCTAssertTrue(sampleRaw.contains("um, I was wondering, um"))
        let queue = makeQueue(in: dir, dependencies: deps)
        let job = MeetingJob(id: UUID(), createdAt: Date(), duration: 90, rawTranscript: sampleRaw, status: .waitingForAI)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        queue.startProcessingQueue()
        await queue.waitUntilIdle()

        let processed = try XCTUnwrap(queue.jobs.first { $0.id == job.id })
        XCTAssertEqual(processed.status, .completed)
        XCTAssertEqual(processed.rawTranscript, sampleRaw, "rawTranscript must never be modified by downstream stages")
        XCTAssertNotEqual(processed.aiFormattedTranscript, sampleRaw)
        XCTAssertFalse(processed.aiFormattedTranscript?.contains("um, ") ?? true)
        XCTAssertEqual(processed.title, "ADR Planning")
        XCTAssertEqual(uploadedRaw.get(), sampleRaw, "Notion receives the untouched raw transcript")
    }

    @MainActor
    func testLocalAudioIsKeptUntilNotionUploadSucceeds() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }

        let uploadFails = ThreadSafeBox(true)
        var deps = QueueDependencies.fake(transcript: "Transcribed text")
        deps.uploadToNotion = { _, onPageCreated in
            if uploadFails.get() { throw FakeStageError(message: "network offline") }
            onPageCreated("page-42")
            return ("page-42", "https://notion.so/page42")
        }
        let queue = makeQueue(in: dir, dependencies: deps)
        let jobId = UUID()
        let audioName = "\(jobId.uuidString).m4a"
        let audioURL = writeDummyAudio(named: audioName, in: queue.recordingsDirectory)

        queue.enqueueReceivedRecording(id: jobId, createdAt: Date(), duration: 45, relativeAudioPath: audioName)
        await queue.waitUntilIdle()

        var job = try XCTUnwrap(queue.jobs.first { $0.id == jobId })
        XCTAssertEqual(job.status, .waitingForNotion)
        XCTAssertEqual(job.rawTranscript, "Transcribed text")
        XCTAssertTrue(job.errorMessage?.contains("network offline") == true)
        XCTAssertEqual(job.localAudioRelativePath, audioName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Audio must stay on disk while the upload has not succeeded")

        uploadFails.set(false)
        queue.retryJob(id: jobId)
        await queue.waitUntilIdle()

        job = try XCTUnwrap(queue.jobs.first { $0.id == jobId })
        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.notionPageId, "page-42")
        XCTAssertNil(job.localAudioRelativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "Audio is removed only after the Notion upload succeeded")
    }

    @MainActor
    func testRetryResumesFromFirstIncompleteStage() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)

        let noTranscript = MeetingJob(id: UUID(), duration: 10, status: .failed, errorMessage: "Transcription failed")
        let transcriptOnly = MeetingJob(id: UUID(), duration: 10, rawTranscript: "Raw", status: .failed, errorMessage: "AI failed")
        let formatted = MeetingJob(id: UUID(), duration: 10, rawTranscript: "Raw", aiFormattedTranscript: "Formatted", status: .failed, errorMessage: "Upload failed")
        for job in [noTranscript, transcriptOnly, formatted] {
            queue.addSyntheticMeeting(job: job, startProcessing: false)
        }

        // Checked synchronously, before the processing loop gets a chance to run.
        queue.retryJob(id: noTranscript.id)
        queue.retryJob(id: transcriptOnly.id)
        queue.retryJob(id: formatted.id)
        func job(_ id: UUID) -> MeetingJob? { queue.jobs.first { $0.id == id } }
        XCTAssertEqual(job(noTranscript.id)?.status, .received)
        XCTAssertEqual(job(transcriptOnly.id)?.status, .waitingForAI)
        XCTAssertEqual(job(formatted.id)?.status, .waitingForNotion)
        XCTAssertTrue([noTranscript, transcriptOnly, formatted].allSatisfy { job($0.id)?.errorMessage == nil && job($0.id)?.retryCount == 1 })

        await queue.waitUntilIdle()
    }

    /// Regression: a job parked at .waitingForAI (no Apple Intelligence) or .waitingForNotion was
    /// re-claimed immediately, so the processing loop never ended. Each job now gets one attempt per pass.
    @MainActor
    func testJobWaitingForAppleIntelligenceIsAttemptedOncePerPass() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }

        let aiChecks = ThreadSafeBox(0)
        var deps = QueueDependencies.fake(aiAvailable: false)
        deps.checkAIAvailability = {
            aiChecks.update { $0 += 1 }
            return (false, "Apple Intelligence is not enabled")
        }
        let queue = makeQueue(in: dir, dependencies: deps)
        let job = MeetingJob(id: UUID(), duration: 30, rawTranscript: "Raw transcript", status: .waitingForAI)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        queue.startProcessingQueue()
        await queue.waitUntilIdle()

        XCTAssertEqual(aiChecks.get(), 1, "The loop must not spin on a job that cannot progress")
        XCTAssertEqual(queue.jobs.first?.status, .waitingForAI)
        XCTAssertEqual(queue.jobs.first?.errorMessage, "Apple Intelligence is not enabled")
        XCTAssertEqual(queue.jobs.first?.rawTranscript, "Raw transcript", "The transcript is kept while waiting")
        XCTAssertFalse(queue.isProcessing)
        XCTAssertNil(queue.activeProcessingJobId)
    }

    @MainActor
    func testMissingNotionCredentialsParkJobWithoutUploading() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }

        let uploads = ThreadSafeBox(0)
        var deps = QueueDependencies.fake()
        deps.notionCredentialsConfigured = { false }
        deps.uploadToNotion = { _, _ in
            uploads.update { $0 += 1 }
            return ("x", "y")
        }
        let queue = makeQueue(in: dir, dependencies: deps)
        let job = MeetingJob(id: UUID(), duration: 30, rawTranscript: "Raw", status: .waitingForAI)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        queue.startProcessingQueue()
        await queue.waitUntilIdle()

        let parked = try XCTUnwrap(queue.jobs.first)
        XCTAssertEqual(parked.status, .waitingForNotion)
        XCTAssertNotNil(parked.aiFormattedTranscript, "AI output is persisted before the Notion stage")
        XCTAssertTrue(parked.errorMessage?.contains("not configured") == true)
        XCTAssertEqual(uploads.get(), 0)
    }

    /// Replaces a placeholder that asserted `activeProcessingJobId != <fresh UUID>` (always true).
    @MainActor
    func testConcurrentQueueProcessingTriggersSingleWorkerClaim() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let logs = LogRecorder()
        defer { logs.stop() }

        let inFlight = ThreadSafeBox(0)
        let maxInFlight = ThreadSafeBox(0)
        let transcribed = ThreadSafeBox<[UUID]>([])
        var deps = QueueDependencies.fake()
        deps.transcribe = { _, jobId in
            inFlight.update { $0 += 1 }
            let current = inFlight.get()
            maxInFlight.update { $0 = max($0, current) }
            try await Task.sleep(nanoseconds: 50_000_000)
            inFlight.update { $0 -= 1 }
            transcribed.update { $0.append(jobId) }
            return "Transcript for \(jobId)"
        }
        let queue = makeQueue(in: dir, dependencies: deps)

        let ids = [UUID(), UUID()]
        for id in ids {
            writeDummyAudio(named: "\(id.uuidString).m4a", in: queue.recordingsDirectory)
            queue.addSyntheticMeeting(
                job: MeetingJob(id: id, duration: 5, localAudioRelativePath: "\(id.uuidString).m4a", status: .received),
                startProcessing: false
            )
        }

        // Three triggers in a row (launch, Watch file arrival, pull-to-refresh) must yield one worker.
        queue.startProcessingQueue()
        queue.startProcessingQueue()
        queue.startProcessingQueue()
        XCTAssertEqual(logs.count(containing: "Queue loop already active"), 2)

        await queue.waitUntilIdle()

        XCTAssertEqual(maxInFlight.get(), 1, "Only one job may be processed at a time")
        XCTAssertEqual(Set(transcribed.get()), Set(ids))
        XCTAssertEqual(transcribed.get().count, 2, "Each job is transcribed exactly once")
        XCTAssertTrue(queue.jobs.allSatisfy { $0.status == .completed })
    }

    /// Replaces a placeholder that called a no-op and asserted `true`.
    @MainActor
    func testBackgroundTaskExpirationHandling() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)

        let job = MeetingJob(id: UUID(), duration: 60, localAudioRelativePath: "never-written.m4a", status: .received)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        let claimed = try XCTUnwrap(queue.claimNextActionableJob())
        XCTAssertEqual(queue.activeProcessingJobId, job.id)
        XCTAssertNil(queue.claimNextActionableJob(), "A second claim is refused while a job is active")

        var inFlight = claimed.job
        inFlight.status = .transcribing
        queue.updateJob(inFlight)

        queue.handleBackgroundTimeExpiration()

        XCTAssertNil(queue.activeProcessingJobId, "Expiration releases the single-worker claim")
        XCTAssertFalse(queue.isProcessing)
        XCTAssertEqual(queue.jobs.first?.status, .received, "The interrupted job is put back into a resumable state")

        // If the reset had not been persisted, relaunch would see .transcribing with no audio and mark it failed.
        XCTAssertEqual(makeQueue(in: dir).jobs.first?.status, .received)
    }

    @MainActor
    func testOriginalAudioRemainsPreservedIfBothTranscriptionEnginesFail() async throws {
        TranscriptionService.resetCircuitBreakerForTesting()
        defer { TranscriptionService.resetCircuitBreakerForTesting() }
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }

        TranscriptionService.speechAnalyzerOverride = { _, _, _ in
            throw TranscriptionError.transcriptionFailed("Primary SpeechAnalyzer failed")
        }
        TranscriptionService.sfSpeechRecognizerOverride = { _, _, _ in
            throw TranscriptionError.transcriptionFailed("Fallback SFSpeechRecognizer failed")
        }

        // Real TranscriptionService stage; only the two speech engines are stubbed.
        var deps = QueueDependencies.fake()
        deps.transcribe = QueueDependencies.live.transcribe
        let queue = makeQueue(in: dir, dependencies: deps)

        let jobId = UUID()
        let audioFilename = "\(jobId.uuidString).m4a"
        let audioURL = queue.recordingsDirectory.appendingPathComponent(audioFilename)
        try SyntheticPipelineRunner.createTestAudioFile(at: audioURL, durationSeconds: 2.0)

        queue.enqueueReceivedRecording(id: jobId, createdAt: Date(), duration: 2.0, relativeAudioPath: audioFilename)
        await queue.waitUntilIdle()

        let failedJob = try XCTUnwrap(queue.jobs.first { $0.id == jobId })
        XCTAssertEqual(failedJob.status, .failed)
        XCTAssertTrue(failedJob.errorMessage?.hasPrefix("Transcription:") == true)
        XCTAssertNil(failedJob.rawTranscript, "rawTranscript must stay nil when transcription fails (never partial)")
        XCTAssertEqual(failedJob.localAudioRelativePath, audioFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Original audio must not be deleted when transcription fails")
        let size = try FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? UInt64 ?? 0
        XCTAssertGreaterThan(size, 1024)

        queue.retryJob(id: jobId)
        XCTAssertEqual(queue.jobs.first { $0.id == jobId }?.status, .received, "A failed job is retryable from .received")
        await queue.waitUntilIdle()
    }

    @MainActor
    func testAudioArrivalWhilePreviousJobProcessingIsQueued() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)

        let firstJobId = UUID()
        let secondJobId = UUID()
        queue.enqueueReceivedRecording(id: firstJobId, createdAt: Date(), duration: 30, relativeAudioPath: "\(firstJobId).m4a")
        queue.enqueueReceivedRecording(id: secondJobId, createdAt: Date(), duration: 45, relativeAudioPath: "\(secondJobId).m4a")

        XCTAssertEqual(queue.jobs.map(\.id), [secondJobId, firstJobId], "Both recordings are queued, newest first")
        XCTAssertTrue(queue.jobs.allSatisfy { $0.status == .received })
        await queue.waitUntilIdle()
    }

    func testBackgroundTaskBoxClearsIdentifierExactlyOnce() {
        let box = BackgroundTaskBox()
        let dummyId = UIBackgroundTaskIdentifier(rawValue: 42)
        box.set(dummyId)
        XCTAssertEqual(box.getAndClear(), dummyId)
        XCTAssertEqual(box.getAndClear(), .invalid, "A second call must not return the identifier again (prevents double endBackgroundTask)")
    }

    // MARK: - Local deletion

    @MainActor
    func testCompletedJobCanBeDeleted() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let jobId = UUID()
        let audioURL = writeDummyAudio(named: "\(jobId.uuidString).m4a", in: queue.recordingsDirectory)

        queue.addSyntheticMeeting(job: MeetingJob(id: jobId, duration: 45, localAudioRelativePath: audioURL.lastPathComponent, status: .completed), startProcessing: false)
        XCTAssertTrue(queue.deleteJob(id: jobId))
        XCTAssertFalse(queue.jobs.contains { $0.id == jobId })
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path), "Local audio file must be deleted")
    }

    @MainActor
    func testFailedJobCanBeDeleted() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let jobId = UUID()
        let audioURL = writeDummyAudio(named: "\(jobId.uuidString).m4a", in: queue.recordingsDirectory)

        queue.addSyntheticMeeting(job: MeetingJob(id: jobId, duration: 30, localAudioRelativePath: audioURL.lastPathComponent, status: .failed, errorMessage: "Test failure"), startProcessing: false)
        XCTAssertTrue(queue.deleteJob(id: jobId))
        XCTAssertFalse(queue.jobs.contains { $0.id == jobId })
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    @MainActor
    func testActiveJobsCannotBeDeleted() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let nonTerminal: [JobStatus] = [.waitingForTransfer, .received, .transcribing, .waitingForAI, .formatting, .waitingForNotion, .uploadingToNotion]

        for status in nonTerminal {
            let jobId = UUID()
            let audioURL = writeDummyAudio(named: "\(jobId.uuidString).m4a", in: queue.recordingsDirectory)
            queue.addSyntheticMeeting(job: MeetingJob(id: jobId, duration: 60, localAudioRelativePath: audioURL.lastPathComponent, status: status), startProcessing: false)

            XCTAssertFalse(queue.deleteJob(id: jobId), "Job with status \(status) must not be deleted")
            XCTAssertTrue(queue.jobs.contains { $0.id == jobId })
            XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path), "Audio of an active job must be kept")
        }
    }

    @MainActor
    func testClaimedJobCannotBeDeletedEvenIfMarkedFailed() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let job = MeetingJob(id: UUID(), duration: 10, status: .received)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        var claimed = try XCTUnwrap(queue.claimNextActionableJob()).job
        claimed.status = .failed
        queue.updateJob(claimed)

        XCTAssertFalse(queue.deleteJob(id: job.id), "The job owned by the worker is protected regardless of status")
        queue.handleBackgroundTimeExpiration()
        XCTAssertTrue(queue.deleteJob(id: job.id))
    }

    @MainActor
    func testDeletingOneJobDoesNotAffectOtherJobs() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let jobA = MeetingJob(id: UUID(), duration: 20, status: .completed)
        let jobB = MeetingJob(id: UUID(), duration: 40, status: .completed)
        queue.addSyntheticMeeting(job: jobA, startProcessing: false)
        queue.addSyntheticMeeting(job: jobB, startProcessing: false)

        XCTAssertTrue(queue.deleteJob(id: jobA.id))
        XCTAssertEqual(queue.jobs.map(\.id), [jobB.id])
    }

    @MainActor
    func testPersistedQueueNoLongerContainsDeletedJobAfterRelaunch() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let kept = MeetingJob(id: UUID(), duration: 10, status: .completed)
        let deleted = MeetingJob(id: UUID(), duration: 10, status: .completed)
        queue.addSyntheticMeeting(job: kept, startProcessing: false)
        queue.addSyntheticMeeting(job: deleted, startProcessing: false)

        XCTAssertTrue(queue.deleteJob(id: deleted.id))

        let relaunched = makeQueue(in: dir)
        XCTAssertEqual(relaunched.jobs.map(\.id), [kept.id], "Persisted queue must not contain the deleted job")
    }

    @MainActor
    func testNotionPageIsNeverTouchedWhenDeletingLocally() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let uploads = ThreadSafeBox(0)
        var deps = QueueDependencies.fake()
        deps.uploadToNotion = { _, _ in
            uploads.update { $0 += 1 }
            return ("x", "y")
        }
        let queue = makeQueue(in: dir, dependencies: deps)
        let job = MeetingJob(id: UUID(), duration: 100, notionPageId: "fake-notion-page-12345",
                             notionPageUrl: "https://notion.so/fake-notion-page-12345", status: .completed)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        XCTAssertTrue(queue.deleteJob(id: job.id))
        XCTAssertFalse(queue.jobs.contains { $0.id == job.id })
        XCTAssertEqual(uploads.get(), 0, "Local deletion must not call any Notion stage")
    }

    @MainActor
    func testMissingLocalAudioDuringDeleteDoesNotCrash() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let job = MeetingJob(id: UUID(), duration: 50, localAudioRelativePath: "non_existent.m4a", status: .completed)
        queue.addSyntheticMeeting(job: job, startProcessing: false)

        XCTAssertTrue(queue.deleteJob(id: job.id), "A missing audio file is a safe no-op")
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    @MainActor
    func testDeletionWhileAnotherJobIsProcessingDoesNotDisruptActiveJob() throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let queue = makeQueue(in: dir)
        let activeJob = MeetingJob(id: UUID(), duration: 120, status: .received)
        let completedJob = MeetingJob(id: UUID(), createdAt: Date().addingTimeInterval(-60), duration: 60, status: .completed)
        queue.addSyntheticMeeting(job: completedJob, startProcessing: false)
        queue.addSyntheticMeeting(job: activeJob, startProcessing: false)

        var claimed = try XCTUnwrap(queue.claimNextActionableJob()).job
        XCTAssertEqual(claimed.id, activeJob.id)
        claimed.status = .transcribing
        queue.updateJob(claimed)

        XCTAssertTrue(queue.deleteJob(id: completedJob.id))
        let active = try XCTUnwrap(queue.jobs.first { $0.id == activeJob.id })
        XCTAssertEqual(active.status, .transcribing)
        XCTAssertEqual(active.duration, 120)
        XCTAssertEqual(queue.activeProcessingJobId, activeJob.id, "Deleting another job must not release the active claim")
    }
}
