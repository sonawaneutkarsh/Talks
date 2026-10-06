import Foundation
import UserNotifications
import BackgroundTasks
import UIKit

// MARK: - Architectural Invariant: Job Queue & Crash Recovery
// 1. Durability: Every state transition is written atomically to Documents/queue.json.
// 2. Crash Recovery: When the app launches or wakes via background tasks, any in-flight
//    or interrupted jobs are automatically claimed, resumed, or recovered.
// 3. Thread Safety: UIBackgroundTaskIdentifier expiration handlers execute immediately
//    and synchronously via BackgroundTaskBox to protect against 0xbaadca11 watchdog kills.
// 4. Processing Pipeline: received -> transcribing -> formatting -> uploadingToNotion -> completed.
// 5. Testability: storage location and pipeline stages are injected (QueueDependencies), so unit
//    tests run against a temporary directory and fake stages instead of the shared app state.

/// The pipeline stages JobQueueManager calls. `.live` wires the real services; tests inject fakes.
public struct QueueDependencies: Sendable {
    public var transcribe: @Sendable (URL, UUID) async throws -> String
    public var checkAIAvailability: @Sendable () async -> (Bool, String)
    public var structureTranscript: @Sendable (String, Date, UUID) async throws -> (String, MeetingIntelligence, String)
    public var notionCredentialsConfigured: @Sendable () async -> Bool
    public var uploadToNotion: @Sendable (MeetingJob, @escaping @Sendable (String) -> Void) async throws -> (String, String)

    public init(
        transcribe: @escaping @Sendable (URL, UUID) async throws -> String,
        checkAIAvailability: @escaping @Sendable () async -> (Bool, String),
        structureTranscript: @escaping @Sendable (String, Date, UUID) async throws -> (String, MeetingIntelligence, String),
        notionCredentialsConfigured: @escaping @Sendable () async -> Bool,
        uploadToNotion: @escaping @Sendable (MeetingJob, @escaping @Sendable (String) -> Void) async throws -> (String, String)
    ) {
        self.transcribe = transcribe
        self.checkAIAvailability = checkAIAvailability
        self.structureTranscript = structureTranscript
        self.notionCredentialsConfigured = notionCredentialsConfigured
        self.uploadToNotion = uploadToNotion
    }

    public static let live = QueueDependencies(
        transcribe: { url, jobId in
            try await TranscriptionService.shared.transcribeAudioFile(at: url, jobId: jobId)
        },
        checkAIAvailability: {
            let result = await MeetingAIService.shared.checkAvailability()
            return (result.isAvailable, result.message)
        },
        structureTranscript: { raw, date, jobId in
            let result = try await MeetingAIService.shared.processTranscript(rawTranscript: raw, date: date, jobId: jobId)
            return (result.formattedTranscript, result.intelligence, result.title)
        },
        notionCredentialsConfigured: {
            let token = NotionService.shared.getApiKey() ?? ""
            let parent = NotionService.shared.getParentPageId() ?? ""
            return !token.isEmpty && !parent.isEmpty
        },
        uploadToNotion: { job, onPageCreated in
            let result = try await NotionService.shared.uploadMeeting(job: job, onPageCreated: onPageCreated)
            return (result.pageId, result.pageUrl)
        }
    )
}

final class BackgroundTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    
    func set(_ id: UIBackgroundTaskIdentifier) {
        lock.lock()
        identifier = id
        lock.unlock()
    }
    
    func getAndClear() -> UIBackgroundTaskIdentifier {
        lock.lock()
        defer { lock.unlock() }
        let current = identifier
        identifier = .invalid
        return current
    }
}

@MainActor
public final class JobQueueManager: ObservableObject {
    public static let shared = JobQueueManager()
    
    public static let bgProcessingTaskIdentifier = "com.personal.talks.processing"
    
    @Published public private(set) var jobs: [MeetingJob] = []
    @Published public private(set) var isProcessing = false
    @Published public private(set) var activeProcessingJobId: UUID? = nil
    
    public let queueFileURL: URL
    public let recordingsDirectory: URL
    private let dependencies: QueueDependencies
    /// When false (unit tests), the manager does not touch BGTaskScheduler, UIApplication background
    /// tasks, or notification permissions, which are process-global and cannot be registered twice.
    private let systemIntegration: Bool
    private var isQueueLoopActive = false
    private var activeProcessingTask: Task<Void, Never>?
    private var bgTaskRegistered = false
    
    /// - Parameters:
    ///   - storageDirectory: Folder that holds `queue.json` and `Recordings/`. Defaults to the app's Documents folder.
    ///   - dependencies: Pipeline stages. Defaults to the real transcription, Apple Intelligence, and Notion services.
    ///   - systemIntegration: Register background tasks and notifications. Pass `false` in tests.
    public init(
        storageDirectory: URL? = nil,
        dependencies: QueueDependencies = .live,
        systemIntegration: Bool = true
    ) {
        PipelineLogger.log(stage: "[LAUNCH] JobQueueManager init ENTER")
        let base = storageDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.queueFileURL = base.appendingPathComponent("queue.json")
        self.recordingsDirectory = base.appendingPathComponent("Recordings", isDirectory: true)
        self.dependencies = dependencies
        self.systemIntegration = systemIntegration
        
        createRecordingsDirectoryIfNeeded()
        loadAndReconcileJobs()
        if systemIntegration {
            requestNotificationPermission()
            registerBackgroundTask()
        }
        // IMPORTANT ARCHITECTURAL INVARIANT:
        // Do NOT start heavy processing loop inside init()!
        // The UI must construct and render its first frame unimpeded.
        // Queue processing is kicked off asynchronously from ContentView.task.
        PipelineLogger.log(stage: "[LAUNCH] JobQueueManager init EXIT")
    }
    
    private func createRecordingsDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: recordingsDirectory.path) {
            try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Persistence & Interrupted Job Reconciliation
    
    public nonisolated static func reconcileInterruptedJobs(_ loaded: [MeetingJob], recordingsDirectory: URL) -> [MeetingJob] {
        var reconciled = loaded
        for index in reconciled.indices {
            var job = reconciled[index]
            let previousStatus = job.status
            
            switch previousStatus {
            case .transcribing:
                // Process was terminated while transcribing
                if let relPath = job.localAudioRelativePath,
                   FileManager.default.fileExists(atPath: recordingsDirectory.appendingPathComponent(relPath).path) {
                    job.status = .received
                    job.errorMessage = nil
                    PipelineLogger.log(stage: "job reconciled", jobId: job.id, details: "Reset .transcribing -> .received (audio on disk)")
                } else {
                    job.status = .failed
                    job.errorMessage = "Source audio file missing on disk after restart"
                    PipelineLogger.log(stage: "job reconciled", jobId: job.id, details: "Marked .failed (missing audio)")
                }
                
            case .formatting:
                // Process was terminated while formatting
                if let raw = job.rawTranscript, !raw.isEmpty {
                    job.status = .waitingForAI
                    job.errorMessage = nil
                    PipelineLogger.log(stage: "job reconciled", jobId: job.id, details: "Reset .formatting -> .waitingForAI (raw transcript exists)")
                } else if let relPath = job.localAudioRelativePath,
                          FileManager.default.fileExists(atPath: recordingsDirectory.appendingPathComponent(relPath).path) {
                    job.status = .received
                    job.errorMessage = nil
                    PipelineLogger.log(stage: "job reconciled", jobId: job.id, details: "Reset .formatting -> .received (audio on disk)")
                } else {
                    job.status = .failed
                    job.errorMessage = "Transcript and audio missing after restart"
                }
                
            case .uploadingToNotion:
                // Process was terminated while uploading
                if job.aiFormattedTranscript != nil {
                    job.status = .waitingForNotion
                    job.errorMessage = nil
                    PipelineLogger.log(stage: "job reconciled", jobId: job.id, details: "Reset .uploadingToNotion -> .waitingForNotion (idempotent resume)")
                } else if job.rawTranscript != nil {
                    job.status = .waitingForAI
                } else {
                    job.status = .received
                }
                
            case .waitingForTransfer:
                if let relPath = job.localAudioRelativePath,
                   FileManager.default.fileExists(atPath: recordingsDirectory.appendingPathComponent(relPath).path) {
                    job.status = .received
                }
                
            default:
                break
            }
            
            reconciled[index] = job
        }
        return reconciled
    }

    public func loadAndReconcileJobs() {
        guard FileManager.default.fileExists(atPath: queueFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: queueFileURL)
            let loaded = try JSONDecoder().decode([MeetingJob].self, from: data)
            let reconciled = Self.reconcileInterruptedJobs(loaded, recordingsDirectory: recordingsDirectory)
            self.jobs = reconciled.sorted { $0.createdAt > $1.createdAt }
            self.activeProcessingJobId = nil
            saveJobs()
        } catch {
            // Keep the unreadable file for diagnosis instead of overwriting it on the next save.
            let backupURL = queueFileURL.deletingLastPathComponent()
                .appendingPathComponent("queue.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: queueFileURL, to: backupURL)
            PipelineLogger.log(stage: "queue load failed", details: "\(error.localizedDescription). Moved unreadable queue to \(backupURL.lastPathComponent)")
            self.jobs = []
            self.activeProcessingJobId = nil
        }
    }
    
    public func saveJobs() {
        do {
            let data = try JSONEncoder().encode(jobs)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            print("[JobQueueManager] Failed to save queue.json: \(error.localizedDescription)")
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }
    
    private func notifySuccess(title: String) {
        guard systemIntegration else { return }
        let content = UNMutableNotificationContent()
        content.title = "Talks"
        content.body = "\(title) — saved to Notion ✓"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    // MARK: - Background Tasks Registration & Scheduling
    
    public func registerBackgroundTask() {
        guard !bgTaskRegistered else { return }
        bgTaskRegistered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgProcessingTaskIdentifier, using: nil) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Task { @MainActor [weak self] in
                self?.handleBackgroundProcessing(task: processingTask)
            }
        }
    }
    
    public func scheduleBackgroundProcessing() {
        guard systemIntegration else { return }
        let request = BGProcessingTaskRequest(identifier: Self.bgProcessingTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Successfully submitted background processing task")
        } catch {
            print("Could not schedule BGProcessingTask: \(error)")
        }
    }
    
    private func handleBackgroundProcessing(task: BGProcessingTask) {
        scheduleBackgroundProcessing() // Schedule next opportunity
        
        task.expirationHandler = { [weak self] in
            PipelineLogger.log(stage: "BGProcessingTask expired", jobId: nil, details: "Cancelling in-flight operations safely")
            Task { @MainActor [weak self] in
                self?.handleBackgroundTimeExpiration()
            }
        }
        
        Task { @MainActor in
            await self.runProcessingLoop()
            task.setTaskCompleted(success: true)
        }
    }
    
    // MARK: - Queue Enqueueing
    
    public func enqueueReceivedRecording(id: UUID, createdAt: Date, duration: TimeInterval, relativeAudioPath: String) {
        if let existingIndex = jobs.firstIndex(where: { $0.id == id }) {
            jobs[existingIndex].localAudioRelativePath = relativeAudioPath
            jobs[existingIndex].duration = duration
            if jobs[existingIndex].status == .waitingForTransfer || jobs[existingIndex].status == .failed {
                jobs[existingIndex].status = .received
            }
        } else {
            let newJob = MeetingJob(
                id: id,
                createdAt: createdAt,
                duration: duration,
                localAudioRelativePath: relativeAudioPath,
                status: .received
            )
            jobs.insert(newJob, at: 0)
        }
        
        saveJobs()
        PipelineLogger.log(stage: "enqueue complete", jobId: id, details: "Path: \(relativeAudioPath), duration: \(duration)s")
        scheduleBackgroundProcessing()
        startProcessingQueue()
    }
    
    // MARK: - Queue Processing Loop & Single-Owner Claim
    
    public func startProcessingQueue() {
        guard !isQueueLoopActive else {
            PipelineLogger.log(stage: "processNextJob entered", jobId: nil, details: "Queue loop already active. Skipping duplicate trigger.")
            return
        }
        isQueueLoopActive = true
        isProcessing = true
        PipelineLogger.log(stage: "processNextJob entered", jobId: nil, details: "Starting processing loop.")
        
        let useBackgroundTask = systemIntegration
        activeProcessingTask = Task { @MainActor in
            let box = BackgroundTaskBox()
            if useBackgroundTask {
                let taskID = UIApplication.shared.beginBackgroundTask(withName: "TalksProcessing") { [weak self] in
                    PipelineLogger.log(stage: "UIBackgroundTask expired", jobId: nil)
                    let current = box.getAndClear()
                    if current != .invalid {
                        UIApplication.shared.endBackgroundTask(current)
                    }
                    Task { @MainActor [weak self] in
                        self?.handleBackgroundTimeExpiration()
                    }
                }
                box.set(taskID)
            }
            
            await self.runProcessingLoop()
            
            self.isQueueLoopActive = false
            self.isProcessing = false
            self.activeProcessingJobId = nil
            
            let finalTaskID = box.getAndClear()
            if finalTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(finalTaskID)
            }
        }
    }
    
    /// Waits for the current processing loop (if any) to finish.
    public func waitUntilIdle() async {
        await activeProcessingTask?.value
    }
    
    /// Called when iOS revokes background execution time: cancel in-flight work, put the
    /// interrupted job back into a resumable state, and release the single-worker claim.
    public func handleBackgroundTimeExpiration() {
        activeProcessingTask?.cancel()
        reconcileInterruptedActiveJob()
        isQueueLoopActive = false
        isProcessing = false
        activeProcessingJobId = nil
    }
    
    // Backward-compatible alias
    public func processNextJobsIfNeeded() {
        startProcessingQueue()
    }
    
    public func reconcileInterruptedActiveJob() {
        guard let currentId = activeProcessingJobId,
              let index = jobs.firstIndex(where: { $0.id == currentId }) else { return }
        
        var job = jobs[index]
        if job.status == .transcribing {
            job.status = .received
        } else if job.status == .formatting {
            job.status = .waitingForAI
        } else if job.status == .uploadingToNotion {
            job.status = .waitingForNotion
        }
        jobs[index] = job
        saveJobs()
    }
    
    /// Claims the first actionable job that is not in `excluded` and makes it the single active job.
    public func claimNextActionableJob(excluding excluded: Set<UUID> = []) -> (index: Int, job: MeetingJob)? {
        guard activeProcessingJobId == nil else { return nil }
        for (index, job) in jobs.enumerated() where !excluded.contains(job.id) {
            if job.status == .received || job.status == .waitingForAI || job.status == .waitingForNotion {
                activeProcessingJobId = job.id
                PipelineLogger.log(stage: "job claimed", jobId: job.id, details: "Status: \(job.status)")
                PipelineLogger.log(stage: "processing owner acquired", jobId: job.id)
                return (index, job)
            }
        }
        return nil
    }
    
    func updateJob(_ updatedJob: MeetingJob) {
        if let idx = jobs.firstIndex(where: { $0.id == updatedJob.id }) {
            jobs[idx] = updatedJob
            saveJobs()
        }
    }
    
    private func runProcessingLoop() async {
        // Each job gets at most one attempt per loop. Without this, a job that stays in
        // .waitingForAI (Apple Intelligence unavailable) or .waitingForNotion (no credentials,
        // network down) is re-claimed immediately and the loop never ends.
        var attemptedThisPass: Set<UUID> = []
        while !Task.isCancelled {
            guard let (_, job) = claimNextActionableJob(excluding: attemptedThisPass) else {
                break
            }
            attemptedThisPass.insert(job.id)
            await processClaimedJob(job: job)
            activeProcessingJobId = nil
        }
    }
    
    public func retryJob(id: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == id }) {
            jobs[index].status = (jobs[index].rawTranscript == nil) ? .received : ((jobs[index].aiFormattedTranscript == nil) ? .waitingForAI : .waitingForNotion)
            jobs[index].errorMessage = nil
            jobs[index].retryCount += 1
            saveJobs()
            startProcessingQueue()
        }
    }
    
    public func retryAllFailedJobs() {
        for index in jobs.indices {
            if jobs[index].status == .failed || jobs[index].status == .waitingForAI || jobs[index].status == .waitingForNotion {
                jobs[index].status = (jobs[index].rawTranscript == nil) ? .received : ((jobs[index].aiFormattedTranscript == nil) ? .waitingForAI : .waitingForNotion)
                jobs[index].errorMessage = nil
            }
        }
        saveJobs()
        startProcessingQueue()
    }
    
    private func processClaimedJob(job: MeetingJob) async {
        var currentJob = job
        currentJob.lastAttemptDate = Date()
        
        // -------------------------------------------------------------
        // Step 1: Transcription
        // -------------------------------------------------------------
        if currentJob.rawTranscript == nil {
            guard let relPath = currentJob.localAudioRelativePath else {
                currentJob.status = .failed
                currentJob.errorMessage = "Audio file missing"
                updateJob(currentJob)
                return
            }
            
            let audioURL = recordingsDirectory.appendingPathComponent(relPath)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                currentJob.status = .failed
                currentJob.errorMessage = "Audio file not found on disk: \(relPath)"
                updateJob(currentJob)
                return
            }
            
            currentJob.status = .transcribing
            updateJob(currentJob)
            PipelineLogger.log(stage: "state -> transcribing", jobId: currentJob.id)
            
            #if DEBUG
            let heartbeatJobId = currentJob.id
            let heartbeatTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { break }
                    PipelineLogger.log(stage: "main heartbeat", jobId: heartbeatJobId, details: "MainActor alive and responsive")
                }
            }
            defer { heartbeatTask.cancel() }
            #endif
            
            do {
                let raw = try await dependencies.transcribe(audioURL, currentJob.id)
                // Critical Invariant: rawTranscript is set and never modified again
                currentJob.rawTranscript = raw
                currentJob.status = .waitingForAI
                updateJob(currentJob)
                PipelineLogger.log(stage: "raw transcript persisted", jobId: currentJob.id, details: "\(raw.count) characters")
            } catch is CancellationError {
                PipelineLogger.log(stage: "transcription cancelled", jobId: currentJob.id, details: "Reverting to .received")
                currentJob.status = .received
                updateJob(currentJob)
                return
            } catch {
                PipelineLogger.log(stage: "transcription error", jobId: currentJob.id, details: error.localizedDescription)
                currentJob.status = .failed
                currentJob.errorMessage = "Transcription: \(error.localizedDescription)"
                updateJob(currentJob)
                return
            }
        }
        
        // -------------------------------------------------------------
        // Step 2: Apple Intelligence Formatting & Intelligence
        // -------------------------------------------------------------
        if currentJob.aiFormattedTranscript == nil || currentJob.intelligence == nil {
            guard let raw = currentJob.rawTranscript else { return }
            
            let (aiAvailable, aiReason) = await dependencies.checkAIAvailability()
            if !aiAvailable {
                // Fail-safe: Keep transcript and job locally, mark Waiting for AI formatting
                currentJob.status = .waitingForAI
                currentJob.errorMessage = aiReason
                updateJob(currentJob)
                return
            }
            
            currentJob.status = .formatting
            updateJob(currentJob)
            PipelineLogger.log(stage: "state -> formatting", jobId: currentJob.id)
            
            do {
                let (formatted, intelligence, title) = try await dependencies.structureTranscript(
                    raw,
                    currentJob.createdAt,
                    currentJob.id
                )
                currentJob.aiFormattedTranscript = formatted
                currentJob.intelligence = intelligence
                currentJob.title = title
                currentJob.status = .waitingForNotion
                updateJob(currentJob)
            } catch is CancellationError {
                PipelineLogger.log(stage: "formatting cancelled", jobId: currentJob.id, details: "Reverting to .waitingForAI")
                currentJob.status = .waitingForAI
                updateJob(currentJob)
                return
            } catch {
                PipelineLogger.log(stage: "formatting error", jobId: currentJob.id, details: error.localizedDescription)
                currentJob.status = .failed
                currentJob.errorMessage = "AI Formatting: \(error.localizedDescription)"
                updateJob(currentJob)
                return
            }
        }
        
        // -------------------------------------------------------------
        // Step 3: Notion Upload
        // -------------------------------------------------------------
        if currentJob.status == .waitingForNotion || currentJob.status == .uploadingToNotion {
            let notionConfigured = await dependencies.notionCredentialsConfigured()
            if !notionConfigured {
                currentJob.status = .waitingForNotion
                currentJob.errorMessage = "Notion token or parent page not configured in Settings."
                updateJob(currentJob)
                return
            }
            
            currentJob.status = .uploadingToNotion
            updateJob(currentJob)
            PipelineLogger.log(stage: "state -> uploading", jobId: currentJob.id)
            
            do {
                let capturedId = currentJob.id
                let (pageId, pageUrl) = try await dependencies.uploadToNotion(
                    currentJob,
                    { [weak self] newPageId in
                        Task { @MainActor [weak self] in
                            guard let self = self,
                                  let idx = self.jobs.firstIndex(where: { $0.id == capturedId }) else { return }
                            self.jobs[idx].notionPageId = newPageId
                            self.saveJobs()
                            PipelineLogger.log(stage: "notion page created", jobId: capturedId, details: "Page ID: \(newPageId)")
                        }
                    }
                )
                
                currentJob.notionPageId = pageId
                currentJob.notionPageUrl = pageUrl
                currentJob.status = .completed
                currentJob.errorMessage = nil
                
                // Privacy & Storage cleanup: safely remove local audio file only after total success
                if let relPath = currentJob.localAudioRelativePath {
                    let audioURL = recordingsDirectory.appendingPathComponent(relPath)
                    try? FileManager.default.removeItem(at: audioURL)
                    currentJob.localAudioRelativePath = nil
                }
                
                updateJob(currentJob)
                PipelineLogger.log(stage: "state -> completed", jobId: currentJob.id, details: "Notion Page: \(pageUrl)")
                
                notifySuccess(title: currentJob.displayTitle)
            } catch is CancellationError {
                PipelineLogger.log(stage: "upload cancelled", jobId: currentJob.id, details: "Reverting to .waitingForNotion")
                currentJob.status = .waitingForNotion
                updateJob(currentJob)
                return
            } catch {
                PipelineLogger.log(stage: "upload error", jobId: currentJob.id, details: error.localizedDescription)
                currentJob.status = .waitingForNotion
                currentJob.errorMessage = "Notion Upload: \(error.localizedDescription)"
                updateJob(currentJob)
                return
            }
        }
    }
    
    // MARK: - Safe Job Deletion (iPhone Local Only)
    
    /// Safely removes a completed or failed Talk and its local audio from this iPhone.
    /// Invariant: Active processing jobs are never deleted.
    /// Invariant: Remote Notion pages are never deleted or modified.
    /// Invariant: No deletion requests are sent to Apple Watch.
    @discardableResult
    public func deleteJob(id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            print("[JobQueueManager] deleteJob failed: Job \(id) not found.")
            return false
        }
        let job = jobs[index]
        
        // Invariant: Do NOT delete actively processing jobs
        guard job.status.isEligibleForDeletion && activeProcessingJobId != id else {
            print("[JobQueueManager] deleteJob rejected: Job \(id) is active or currently processing (status: \(job.status)).")
            return false
        }
        
        // Safely remove local audio file if it exists
        if let relPath = job.localAudioRelativePath {
            let audioURL = recordingsDirectory.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                do {
                    try FileManager.default.removeItem(at: audioURL)
                    PipelineLogger.log(stage: "audio deleted", jobId: id, details: "Removed \(audioURL.lastPathComponent)")
                } catch {
                    print("[JobQueueManager] ERROR: Failed to remove local audio file at \(audioURL.path): \(error.localizedDescription)")
                    // Conservative decision: Keep job entry so user knows cleanup was incomplete
                    jobs[index].errorMessage = "Failed to delete local audio: \(error.localizedDescription)"
                    saveJobs()
                    return false
                }
            }
        }
        
        // Remove the job record from memory and disk
        jobs.remove(at: index)
        saveJobs()
        PipelineLogger.log(stage: "job deleted", jobId: id, details: "Local Talk and storage removed. Notion page untouched.")
        return true
    }
    
    // For direct manual addition (e.g. synthetic test meeting)
    public func addSyntheticMeeting(job: MeetingJob, startProcessing: Bool = true) {
        jobs.insert(job, at: 0)
        saveJobs()
        if startProcessing {
            startProcessingQueue()
        }
    }
    
    #if DEBUG
    public func removeJobForTesting(id: UUID) {
        if let idx = jobs.firstIndex(where: { $0.id == id }) {
            jobs.remove(at: idx)
            saveJobs()
        }
    }
    #endif
}
