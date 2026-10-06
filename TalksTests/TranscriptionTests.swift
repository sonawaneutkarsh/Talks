import XCTest
import AVFoundation
@testable import Talks

/// Audio integrity, transcript chunking, and the speech watchdog / fallback path.
/// Speech engines are replaced through TranscriptionService's test hooks; the watchdog,
/// circuit breaker, file checks, and fallback ordering are the production code.
final class TranscriptionTests: XCTestCase {

    override func tearDown() {
        TranscriptionService.resetCircuitBreakerForTesting()
        PipelineLogger.logListener = nil
        super.tearDown()
    }

    // MARK: - Audio files

    func testAudioFormatSettingsAndFileCreation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test_recording_\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try SyntheticPipelineRunner.createTestAudioFile(at: url, durationSeconds: 2.0)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
        XCTAssertGreaterThan(size, 1024)
        let audioFile = try AVAudioFile(forReading: url)
        XCTAssertEqual(audioFile.fileFormat.channelCount, 1, "Recording format must be mono")
        XCTAssertEqual(audioFile.fileFormat.sampleRate, TalksConstants.Audio.sampleRate)
        XCTAssertGreaterThan(audioFile.length, 0)
    }

    /// Previously this test only compared file sizes with literals; it now goes through TranscriptionService.
    func testTranscriptionRejectsMissingEmptyAndTruncatedAudio() async throws {
        let dir = try makeTempDirectory()
        defer { removeDirectory(dir) }
        let engineCalls = ThreadSafeBox(0)
        TranscriptionService.speechAnalyzerOverride = { _, _, _ in engineCalls.update { $0 += 1 }; return "should not run" }
        TranscriptionService.sfSpeechRecognizerOverride = { _, _, _ in engineCalls.update { $0 += 1 }; return "should not run" }

        do {
            _ = try await TranscriptionService.shared.transcribeAudioFile(at: dir.appendingPathComponent("missing.m4a"))
            XCTFail("Missing audio must throw")
        } catch TranscriptionError.audioFileNotFound {
        } catch {
            XCTFail("Expected audioFileNotFound, got \(error)")
        }

        for (name, bytes) in [("zero.m4a", 0), ("truncated.m4a", 256)] {
            let url = writeDummyAudio(named: name, in: dir, bytes: bytes)
            do {
                _ = try await TranscriptionService.shared.transcribeAudioFile(at: url)
                XCTFail("\(bytes)-byte audio must be rejected")
            } catch TranscriptionError.emptyOrCorruptAudioFile {
            } catch {
                XCTFail("Expected emptyOrCorruptAudioFile for \(bytes) bytes, got \(error)")
            }
        }
        XCTAssertEqual(engineCalls.get(), 0, "No speech engine may run on missing or corrupt audio")
    }

    // MARK: - Chunking for on-device model context limits

    func testHierarchicalChunking30Min60Min90MinMeetings() {
        for duration in [30, 60, 90] {
            let paragraphCount = duration * 2
            let transcript = (1...paragraphCount).map { p in
                "Speaker \(p % 2 == 0 ? "A" : "B") [Turn \(p) of \(duration)m meeting]: Let's analyze the anomaly detection pipeline behavior on the telemetry benchmark. We observe that reconstruction loss under extreme variance shows significant deviations when comparing the deep autoencoder against the standard isolation forest baseline. Furthermore, we must verify the mathematical loss formulation in Section 3 and confirm whether Mahalanobis distance bounds provide useful constraints before the upcoming submission deadline."
            }.joined(separator: "\n\n")

            let chunks = MeetingAIService.shared.splitIntoChunks(text: transcript, targetSize: 3500)

            XCTAssertGreaterThan(chunks.count, duration / 10, "A \(duration) minute meeting must be split into several chunks")
            XCTAssertTrue(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            let reconstructed = chunks.joined(separator: "\n\n")
            for p in 1...paragraphCount {
                XCTAssertTrue(reconstructed.contains("[Turn \(p) of \(duration)m meeting]"), "Turn \(p) lost in \(duration)m meeting")
            }
        }
    }

    func test120MinuteSyntheticTranscriptChunking() {
        let paragraphCount = 240
        let transcript = (1...paragraphCount).map { p in
            "Speaker \(p % 2 == 0 ? "A" : "B") [Turn \(p) of 120m]: Telemetry calibration and loss convergence analysis under anomaly detection constraints. Benchmark verification ensures all parameters satisfy the Mahalanobis distance bound. We must also evaluate autoencoder reconstruction loss across multiple epochs and cross-reference with isolation forest baselines to ensure complete convergence before final reporting."
        }.joined(separator: "\n\n")
        XCTAssertGreaterThan(transcript.count, 90_000)

        let chunks = MeetingAIService.shared.splitIntoChunks(text: transcript, targetSize: 3500)
        XCTAssertGreaterThan(chunks.count, 15)
        XCTAssertTrue(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let reconstructed = chunks.joined(separator: "\n\n")
        for p in [1, 50, 100, 150, 200, paragraphCount] {
            XCTAssertTrue(reconstructed.contains("[Turn \(p) of 120m]"))
        }
    }

    // MARK: - Watchdog

    func testSpeechWatchdogTimeoutCancelsAndFailsGracefully() async {
        do {
            _ = try await TranscriptionService.withTimeout(seconds: 0.1) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "completed"
            }
            XCTFail("withTimeout should have thrown")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
        }
    }

    func testWatchdogEscapesUncooperativeChildTaskThatIgnoresCancellation() async throws {
        let start = Date()
        let watchdogFired = ThreadSafeBox(false)
        let childFinished = ThreadSafeBox(false)

        do {
            _ = try await TranscriptionService.withTimeout(seconds: 0.15, onTimeout: { watchdogFired.set(true) }) {
                let childStart = Date()
                while Date().timeIntervalSince(childStart) < 1.5 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // ignores cancellation on purpose
                }
                childFinished.set(true)
                return "completed after delay"
            }
            XCTFail("withTimeout must throw for an uncooperative operation")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertTrue(watchdogFired.get())
            XCTAssertLessThan(elapsed, 0.6, "Watchdog must return promptly without awaiting the 1.5s child (took \(elapsed)s)")
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }

        let waitStart = Date()
        while !childFinished.get() && Date().timeIntervalSince(waitStart) < 2.5 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(childFinished.get(), "Child task should end on its own within the bounded window")
    }

    /// Previously this test re-implemented the fallback in test code. It now drives
    /// TranscriptionService.transcribeAudioFile with a SpeechAnalyzer stand-in that hangs.
    func testSpeechPipelineRecoversFromHangingSpeechAnalyzerViaFallback() async throws {
        TranscriptionService.resetCircuitBreakerForTesting()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hang_\(UUID().uuidString).m4a")
        try SyntheticPipelineRunner.createTestAudioFile(at: url, durationSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let logs = LogRecorder()
        defer { logs.stop() }
        let childFinished = ThreadSafeBox(false)
        TranscriptionService.analyzerTimeoutSecondsOverride = 0.15
        TranscriptionService.speechAnalyzerOverride = { _, _, _ in
            let childStart = Date()
            while Date().timeIntervalSince(childStart) < 1.5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            childFinished.set(true)
            return "late primary result"
        }
        TranscriptionService.sfSpeechRecognizerOverride = { _, _, _ in
            "Professor discussed reinforcement learning bounds."
        }

        let start = Date()
        let raw = try await TranscriptionService.shared.transcribeAudioFile(at: url, jobId: UUID())
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(raw, "Professor discussed reinforcement learning bounds.")
        XCTAssertLessThan(elapsed, 1.2, "Fallback must start as soon as the watchdog fires (took \(elapsed)s)")
        XCTAssertTrue(logs.contains("speech analyzer watchdog fired"))
        XCTAssertTrue(logs.contains("fallback starting"))
        XCTAssertTrue(TranscriptionService.isCircuitBreakerTripped)

        let waitStart = Date()
        while !childFinished.get() && Date().timeIntervalSince(waitStart) < 2.5 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testSecondJobBypassesSpeechAnalyzerAfterFirstAttemptBecomesUncooperative() async throws {
        TranscriptionService.resetCircuitBreakerForTesting()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("circuit_breaker_\(UUID().uuidString).m4a")
        try SyntheticPipelineRunner.createTestAudioFile(at: url, durationSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let logs = LogRecorder()
        defer { logs.stop() }
        let analyzerCalls = ThreadSafeBox(0)
        let childFinished = ThreadSafeBox(false)
        TranscriptionService.analyzerTimeoutSecondsOverride = 0.15
        TranscriptionService.speechAnalyzerOverride = { _, _, _ in
            analyzerCalls.update { $0 += 1 }
            let childStart = Date()
            while Date().timeIntervalSince(childStart) < 1.5 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            childFinished.set(true)
            return "late output"
        }
        TranscriptionService.sfSpeechRecognizerOverride = { _, _, _ in "Fallback transcript successfully completed" }

        let result1 = try await TranscriptionService.shared.transcribeAudioFile(at: url, jobId: UUID())
        XCTAssertEqual(result1, "Fallback transcript successfully completed")
        XCTAssertEqual(analyzerCalls.get(), 1)
        XCTAssertTrue(TranscriptionService.isCircuitBreakerTripped)
        XCTAssertTrue(logs.contains("speech analyzer disabled for current session after uncooperative timeout"))

        let result2 = try await TranscriptionService.shared.transcribeAudioFile(at: url, jobId: UUID())
        XCTAssertEqual(result2, "Fallback transcript successfully completed")
        XCTAssertEqual(analyzerCalls.get(), 1, "SpeechAnalyzer must be bypassed for the second job")
        XCTAssertTrue(logs.contains("bypassing speech analyzer due to previous timeout"))

        let waitStart = Date()
        while !childFinished.get() && Date().timeIntervalSince(waitStart) < 2.5 {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testFinalizeTimeoutCannotPersistPartialPrimaryTranscriptAsRawTranscript() async throws {
        TranscriptionService.resetCircuitBreakerForTesting()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("finalize_timeout_\(UUID().uuidString).m4a")
        try SyntheticPipelineRunner.createTestAudioFile(at: url, durationSeconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let logs = LogRecorder()
        defer { logs.stop() }
        let partialPrimaryText = "Partial text before finalize hung"
        let completeFallbackText = "Complete and unbroken raw transcript from SFSpeechRecognizer fallback"

        // Stand-in for the SpeechAnalyzer path after its finalize step timed out.
        TranscriptionService.speechAnalyzerOverride = { _, jobId, attemptId in
            TranscriptionService.tripCircuitBreaker(jobId: jobId, attemptId: attemptId)
            throw TranscriptionError.transcriptionFailed("SpeechAnalyzer finalize timed out after 5.0s (partial: \(partialPrimaryText))")
        }
        TranscriptionService.sfSpeechRecognizerOverride = { _, _, _ in completeFallbackText }

        let finalResult = try await TranscriptionService.shared.transcribeAudioFile(at: url, jobId: UUID())

        XCTAssertEqual(finalResult, completeFallbackText)
        XCTAssertFalse(finalResult.contains(partialPrimaryText), "The raw transcript must never be the incomplete primary text")
        XCTAssertTrue(logs.contains("speech analyzer fallback triggered"))
        XCTAssertTrue(logs.contains("speech analyzer disabled for current session after uncooperative timeout"))
    }
}
