import Foundation
import Speech
import AVFoundation

// MARK: - Architectural Invariant: 100% On-Device Speech Transcription
// 1. Zero Cloud: Recognition executes strictly on device without third-party cloud STT.
// 2. Cancellation-Resistant Watchdog: SpeechAnalyzer operations run within isolated tasks
//    governed by TaskTimeoutWatchdog. If an analyzer operation hangs during finalization,
//    the watchdog escapes immediately and triggers full audio transcription via the fallback engine.
// 3. Dual-Engine Fallback: Primary engine is modern SpeechAnalyzer under #available(iOS 26.0, *).
//    On older supported iOS versions, or if assets are missing / execution times out, the
//    SFSpeechRecognizer on-device engine completes the work.

public enum TranscriptionError: LocalizedError {
    case speechRecognitionUnavailable
    case onDeviceRecognitionUnsupported
    case audioFileNotFound(String)
    case emptyOrCorruptAudioFile(String)
    case transcriptionFailed(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .speechRecognitionUnavailable:
            return "Speech recognition service is not available on this device."
        case .onDeviceRecognitionUnsupported:
            return "On-device speech recognition is not supported for this device or locale ($0 cloud-free invariant violated)."
        case .audioFileNotFound(let path):
            return "Audio file not found at path: \(path)"
        case .emptyOrCorruptAudioFile(let path):
            return "Audio file at \(path) is empty or corrupted."
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .cancelled:
            return "Transcription was cancelled."
        }
    }
}

public actor TranscriptionService {
    public static let shared = TranscriptionService()
    
    // Process/session-level circuit breaker for SpeechAnalyzer
    private static let circuitBreakerLock = NSLock()
    nonisolated(unsafe) private static var _isSpeechAnalyzerDisabledForSession = false
    
    // Test injection hooks
    nonisolated(unsafe) public static var speechAnalyzerOverride: (@Sendable (URL, UUID?, String) async throws -> String)?
    nonisolated(unsafe) public static var sfSpeechRecognizerOverride: (@Sendable (URL, UUID?, String) async throws -> String)?
    nonisolated(unsafe) public static var finalizeTimeoutSecondsOverride: TimeInterval?
    nonisolated(unsafe) public static var analyzerTimeoutSecondsOverride: TimeInterval?

    public static var isCircuitBreakerTripped: Bool {
        circuitBreakerLock.lock()
        defer { circuitBreakerLock.unlock() }
        return _isSpeechAnalyzerDisabledForSession
    }
    
    public static func tripCircuitBreaker(jobId: UUID? = nil, attemptId: String = "") {
        circuitBreakerLock.lock()
        let wasTripped = _isSpeechAnalyzerDisabledForSession
        _isSpeechAnalyzerDisabledForSession = true
        circuitBreakerLock.unlock()
        
        if !wasTripped {
            PipelineLogger.log(
                stage: "speech analyzer disabled for current session after uncooperative timeout",
                jobId: jobId,
                details: attemptId.isEmpty ? "" : "attempt: \(attemptId)"
            )
        }
    }
    
    public static func resetCircuitBreakerForTesting() {
        circuitBreakerLock.lock()
        defer { circuitBreakerLock.unlock() }
        _isSpeechAnalyzerDisabledForSession = false
        speechAnalyzerOverride = nil
        sfSpeechRecognizerOverride = nil
        finalizeTimeoutSecondsOverride = nil
        analyzerTimeoutSecondsOverride = nil
    }
    
    public func isAvailable() -> Bool {
        if #available(iOS 26.0, *) {
            if SpeechTranscriber.isAvailable {
                return true
            }
        }
        guard let recognizer = SFSpeechRecognizer() else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }
    
    /// Transcribes an audio file completely on-device, returning the immutable raw transcript.
    public func transcribeAudioFile(at url: URL, jobId: UUID? = nil) async throws -> String {
        let attemptId = UUID().uuidString.prefix(8).description
        PipelineLogger.log(stage: "transcription task created", jobId: jobId, details: "Path: \(url.lastPathComponent), attempt: \(attemptId)")
        
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.audioFileNotFound(url.path)
        }
        
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? UInt64 ?? 0
        guard size > 1024 else {
            throw TranscriptionError.emptyOrCorruptAudioFile(url.lastPathComponent)
        }
        
        // Audio Duration Check
        let audioAsset = AVURLAsset(url: url)
        let durationSeconds = (try? await audioAsset.load(.duration).seconds) ?? 30.0
        let effectiveDuration = max(10.0, durationSeconds)
        PipelineLogger.log(stage: "audio input opened", jobId: jobId, details: "Size: \(size) bytes, duration: \(String(format: "%.1f", effectiveDuration))s, attempt: \(attemptId)")
        
        // Request authorization if needed (bypass prompt under test runner)
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isTesting {
            let currentAuth = SFSpeechRecognizer.authorizationStatus()
            if currentAuth != .authorized {
                let authStatus = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { status in
                        continuation.resume(returning: status)
                    }
                }
                guard authStatus == .authorized else {
                    throw TranscriptionError.transcriptionFailed("Speech recognition authorization was denied or restricted.")
                }
            }
        }
        
        // 1. Try modern iOS 26 SpeechAnalyzer + SpeechTranscriber API with strict watchdog & circuit breaker
        let canUseSpeechAnalyzer: Bool
        if Self.speechAnalyzerOverride != nil {
            canUseSpeechAnalyzer = true
        } else if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            canUseSpeechAnalyzer = true
        } else {
            canUseSpeechAnalyzer = false
        }
        
        if canUseSpeechAnalyzer {
            if Self.isCircuitBreakerTripped {
                PipelineLogger.log(
                    stage: "bypassing speech analyzer due to previous timeout",
                    jobId: jobId,
                    details: "attempt: \(attemptId)"
                )
            } else {
                let analyzerTimeout = Self.analyzerTimeoutSecondsOverride ?? max(30.0, effectiveDuration * 2.0)
                PipelineLogger.log(stage: "speech analyzer watchdog started", jobId: jobId, details: "attempt: \(attemptId), timeout: \(String(format: "%.1f", analyzerTimeout))s")
                
                do {
                    let raw = try await Self.withTimeout(
                        seconds: analyzerTimeout,
                        onTimeout: {
                            PipelineLogger.log(stage: "speech analyzer watchdog fired", jobId: jobId, details: "attempt: \(attemptId)")
                            PipelineLogger.log(stage: "speech analyzer cancellation requested", jobId: jobId, details: "attempt: \(attemptId)")
                            PipelineLogger.log(stage: "speech analyzer attempt abandoned", jobId: jobId, details: "attempt: \(attemptId) | Proceeding immediately to fallback")
                            Self.tripCircuitBreaker(jobId: jobId, attemptId: attemptId)
                        }
                    ) {
                        if let override = Self.speechAnalyzerOverride {
                            return try await override(url, jobId, attemptId)
                        } else {
                            if #available(iOS 26.0, *) {
                                return try await self.transcribeWithSpeechAnalyzer(at: url, jobId: jobId, attemptId: attemptId)
                            } else {
                                throw TranscriptionError.transcriptionFailed("SpeechAnalyzer unavailable on this platform.")
                            }
                        }
                    }
                    PipelineLogger.log(stage: "transcription finalized", jobId: jobId, details: "SpeechAnalyzer completed (\(raw.count) chars), attempt: \(attemptId)")
                    return raw
                } catch {
                    PipelineLogger.log(stage: "speech analyzer fallback triggered", jobId: jobId, details: "attempt: \(attemptId) | Error: \(error.localizedDescription). Falling back to SFSpeechRecognizer.")
                }
            }
        }
        
        // 2. Fallback to SFSpeechRecognizer with strict on-device recognition and watchdog timeout
        PipelineLogger.log(stage: "fallback starting", jobId: jobId, details: "attempt: \(attemptId)")
        let recognizerTimeout = max(45.0, effectiveDuration * 2.5)
        PipelineLogger.log(stage: "SFSpeechRecognizer started", jobId: jobId, details: "attempt: \(attemptId), timeout: \(Int(recognizerTimeout))s")
        let raw = try await Self.withTimeout(seconds: recognizerTimeout) {
            try await self.transcribeWithSFSpeechRecognizer(at: url, jobId: jobId, attemptId: attemptId)
        }
        PipelineLogger.log(stage: "fallback finalized", jobId: jobId, details: "attempt: \(attemptId) | count: \(raw.count) chars")
        PipelineLogger.log(stage: "transcription completed", jobId: jobId, details: "Total \(raw.count) chars, attempt: \(attemptId)")
        return raw
    }
    
    @available(iOS 26.0, *)
    private func transcribeWithSpeechAnalyzer(at url: URL, jobId: UUID?, attemptId: String) async throws -> String {
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw TranscriptionError.emptyOrCorruptAudioFile(url.lastPathComponent)
        }
        
        let locale = Locale.current
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        
        PipelineLogger.log(stage: "speech asset check started", jobId: jobId, details: "attempt: \(attemptId)")
        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        PipelineLogger.log(stage: "speech asset check finished", jobId: jobId, details: "status: \(assetStatus), attempt: \(attemptId)")
        
        if assetStatus == .supported {
            // Attempt asset download with strict 5-second timeout; if asset not already installed, fall back to SFSpeechRecognizer
            do {
                try await Self.withTimeout(seconds: 5.0) {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                }
            } catch {
                PipelineLogger.log(stage: "speech asset download skipped", jobId: jobId, details: "Asset not pre-installed or timeout: \(error.localizedDescription), attempt: \(attemptId)")
                throw TranscriptionError.transcriptionFailed("Speech asset not immediately available on device.")
            }
        }
        
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        PipelineLogger.log(stage: "speech model initialization finished", jobId: jobId, details: "attempt: \(attemptId)")
        
        let accumulator = ResultAccumulator()
        
        // Stream results from the transcriber async sequence safely into accumulator
        let collectionTask = Task {
            do {
                for try await result in transcriber.results {
                    if Task.isCancelled { break }
                    if accumulator.markFirstResult() {
                        PipelineLogger.log(stage: "first transcription result received", jobId: jobId, details: "attempt: \(attemptId)")
                    }
                    if result.isFinal {
                        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            accumulator.append(text)
                        }
                    }
                }
            } catch {
                print("Transcriber result stream closed: \(error)")
            }
        }
        
        PipelineLogger.log(stage: "first audio chunk submitted", jobId: jobId, details: "attempt: \(attemptId)")
        _ = try await analyzer.analyzeSequence(from: audioFile)
        PipelineLogger.log(stage: "audio input completed", jobId: jobId, details: "attempt: \(attemptId)")
        
        PipelineLogger.log(stage: "finalize requested", jobId: jobId, details: "attempt: \(attemptId)")
        
        // Bounded finalization: give analyzer up to 5 seconds to finish through end of input
        let finalizeTimeout = Self.finalizeTimeoutSecondsOverride ?? 5.0
        do {
            try await Self.withTimeout(seconds: finalizeTimeout) {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            PipelineLogger.log(stage: "finalize completed", jobId: jobId, details: "attempt: \(attemptId)")
        } catch {
            Self.tripCircuitBreaker(jobId: jobId, attemptId: attemptId)
            PipelineLogger.log(stage: "speech analyzer cancellation requested", jobId: jobId, details: "attempt: \(attemptId)")
            PipelineLogger.log(stage: "speech analyzer attempt abandoned", jobId: jobId, details: "attempt: \(attemptId) | Finalize timed out. Proceeding immediately to fallback")
            
            collectionTask.cancel()
            #if DEBUG
            let partial = accumulator.currentTranscript()
            if !partial.isEmpty {
                PipelineLogger.log(stage: "speech analyzer partial discarded", jobId: jobId, details: "Discarded partial (\(partial.count) chars) due to finalize timeout")
            }
            #endif
            throw TranscriptionError.transcriptionFailed("SpeechAnalyzer finalize timed out after \(finalizeTimeout)s")
        }
        
        // Allow up to 1.5 seconds for final results to land in accumulator
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        collectionTask.cancel()
        
        // Read directly from accumulator without awaiting collectionTask.value
        let fullTranscript = accumulator.currentTranscript()
        if !fullTranscript.isEmpty {
            return fullTranscript
        }
        
        throw TranscriptionError.transcriptionFailed("SpeechAnalyzer produced an empty transcript.")
    }
    
    private func transcribeWithSFSpeechRecognizer(at url: URL, jobId: UUID?, attemptId: String) async throws -> String {
        if let override = Self.sfSpeechRecognizerOverride {
            return try await override(url, jobId, attemptId)
        }
        
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw TranscriptionError.speechRecognitionUnavailable
        }
        
        guard recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.onDeviceRecognitionUnsupported
        }
        
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error = error {
                    if !hasResumed {
                        hasResumed = true
                        continuation.resume(throwing: TranscriptionError.transcriptionFailed(error.localizedDescription))
                    }
                    return
                }
                
                if let result = result, result.isFinal {
                    if !hasResumed {
                        hasResumed = true
                        PipelineLogger.log(stage: "fallback first result", jobId: jobId, details: "attempt: \(attemptId)")
                        let raw = result.bestTranscription.formattedString
                        continuation.resume(returning: raw)
                    }
                }
            }
            _ = task
        }
    }
    
    /// Watchdog wrapper that genuinely escapes and returns control even if operation ignores cancellation
    public static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        timeoutError: Error? = nil,
        onTimeout: (@Sendable () -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withCheckedThrowingContinuation { continuation in
            let state = AtomicCompletionState()
            
            let opTask = Task {
                do {
                    let result = try await operation()
                    if state.completeOnce() {
                        continuation.resume(returning: result)
                    }
                } catch {
                    if state.completeOnce() {
                        continuation.resume(throwing: error)
                    }
                }
            }
            
            let timerTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if state.completeOnce() {
                    opTask.cancel()
                    onTimeout?()
                    let err = timeoutError ?? TranscriptionError.transcriptionFailed("Operation timed out after \(Int(seconds))s")
                    continuation.resume(throwing: err)
                }
            }
            
            _ = (opTask, timerTask)
        }
    }
}

// MARK: - Thread-safe Coordination Helpers

final class AtomicCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var isCompleted = false
    
    func completeOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCompleted { return false }
        isCompleted = true
        return true
    }
}

final class ResultAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments: [String] = []
    private var hasFirstResult = false
    
    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        fragments.append(text)
    }
    
    func markFirstResult() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasFirstResult { return false }
        hasFirstResult = true
        return true
    }
    
    func currentTranscript() -> String {
        lock.lock()
        defer { lock.unlock() }
        return fragments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
