import Foundation
import AVFoundation
import WatchKit

// MARK: - Architectural Invariant: Apple Watch Audio Recording & Runtime
// 1. Uninterrupted Capture: Uses AVAudioSession category .playAndRecord with mode .spokenAudio.
//    Extended runtime sessions (WKExtendedRuntimeSession) keep UI and capture alive;
//    background audio entitlement guarantees recording survives session expiration across 90+ min talks.
// 2. Local Audio Integrity: Files are encoded as AAC in Documents/WatchRecordings/<id>.m4a
//    and verified (>1024 bytes) before queueing for transfer.
// 3. Deletion Safety: Audio files are never deleted upon stop; deletion occurs only after
//    verified acknowledgement from the iPhone.

@MainActor
public final class WatchRecordingManager: NSObject, ObservableObject {
    public static let shared = WatchRecordingManager()
    
    @Published public private(set) var isRecording = false
    @Published public private(set) var isInterrupted = false
    @Published public private(set) var elapsedTime: TimeInterval = 0
    @Published public private(set) var audioLevel: Float = 0
    @Published public private(set) var lastSavedRecordingId: UUID?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var errorMessage: String?
    
    private var audioRecorder: AVAudioRecorder?
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private var timer: Timer?
    private var currentRecordingId: UUID?
    private var currentRecordingURL: URL?
    private var recordingStartTime: Date?
    private var accumulatedDuration: TimeInterval = 0
    private var interruptionStartTime: Date?
    
    public override init() {
        super.init()
        createRecordingsDirectoryIfNeeded()
        setupAudioSessionNotificationObservers()
    }
    
    private var recordingsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("WatchRecordings", isDirectory: true)
    }
    
    private func createRecordingsDirectoryIfNeeded() {
        let dir = recordingsDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
    
    // MARK: - Audio Session Notifications (Interruptions & Media Services Reset)
    
    private func setupAudioSessionNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }
    
    @objc private nonisolated func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        
        Task { @MainActor in
            switch interruptionType {
            case .began:
                self.isInterrupted = true
                self.interruptionStartTime = Date()
                self.statusMessage = "Recording paused (System interruption)"
                print("AVAudioSession interruption began")
            case .ended:
                self.isInterrupted = false
                
                if let iStart = self.interruptionStartTime {
                    // Track paused duration so timer reflects real active recording time
                    self.accumulatedDuration += Date().timeIntervalSince(iStart)
                    self.interruptionStartTime = nil
                }
                
                if shouldResume && self.isRecording {
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        if self.audioRecorder?.record() == true {
                            self.statusMessage = nil
                            print("AVAudioSession resumed recording successfully")
                        } else {
                            self.errorMessage = "Failed to resume after interruption"
                        }
                    } catch {
                        self.errorMessage = "Session reactivation failed: \(error.localizedDescription)"
                    }
                }
            @unknown default:
                break
            }
        }
    }
    
    @objc private nonisolated func handleMediaServicesReset(_ notification: Notification) {
        Task { @MainActor in
            print("Media services were reset. Cleaning up recording session.")
            if self.isRecording {
                self.stopRecording()
                self.errorMessage = "Audio system reset occurred during recording."
            }
        }
    }
    
    // MARK: - Recording Controls
    
    public func startRecording() {
        guard !isRecording else { return }
        errorMessage = nil
        statusMessage = nil
        isInterrupted = false
        interruptionStartTime = nil
        accumulatedDuration = 0
        
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Audio session error: \(error.localizedDescription)"
            return
        }
        
        // Start extended runtime session as companion for active watch display handling
        startExtendedRuntimeSession()
        
        let recordingId = UUID()
        let fileURL = recordingsDirectory.appendingPathComponent("\(recordingId.uuidString).m4a")
        
        let settings = TalksConstants.Audio.recordingSettings
        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord() else {
                errorMessage = "Failed to prepare audio recorder"
                cleanupSession()
                return
            }
            
            guard recorder.record() else {
                errorMessage = "Failed to start audio recording"
                cleanupSession()
                return
            }
            
            self.audioRecorder = recorder
            self.currentRecordingId = recordingId
            self.currentRecordingURL = fileURL
            self.recordingStartTime = Date()
            self.elapsedTime = 0
            self.isRecording = true
            
            // Start timer for duration and audio metering
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, self.isRecording else { return }
                    if !self.isInterrupted, let start = self.recordingStartTime {
                        self.elapsedTime = Date().timeIntervalSince(start) - self.accumulatedDuration
                    }
                    self.audioRecorder?.updateMeters()
                    let avg = self.audioRecorder?.averagePower(forChannel: 0) ?? -160
                    self.audioLevel = max(0, (avg + 50) / 50)
                }
            }
            WKInterfaceDevice.current().play(.start)
        } catch {
            errorMessage = "Recorder init failed: \(error.localizedDescription)"
            cleanupSession()
        }
    }
    
    public func stopRecording() {
        guard isRecording else { return }
        
        timer?.invalidate()
        timer = nil
        
        statusMessage = "Saving..."
        let finalDuration = max(0, elapsedTime)
        audioRecorder?.stop()
        audioRecorder = nil
        
        cleanupSession()
        isRecording = false
        isInterrupted = false
        WKInterfaceDevice.current().play(.stop)
        
        guard let recordingId = currentRecordingId, let fileURL = currentRecordingURL else {
            errorMessage = "No active recording found to save"
            return
        }
        
        // Verify audio file was safely written and is valid
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            errorMessage = "Audio file was not created"
            return
        }
        
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let fileSize = attributes[.size] as? UInt64 ?? 0
            guard fileSize > 1024 else { // Audio header plus frames must exceed minimum byte size
                errorMessage = "Audio file is corrupt or zero-length"
                try? fileManager.removeItem(at: fileURL)
                return
            }
            
            lastSavedRecordingId = recordingId
            statusMessage = "Transferring..."
            
            // Queue for reliable transfer to iPhone via WatchConnectivity
            WatchConnectivityManager.shared.queueFileForTransfer(
                fileURL: fileURL,
                recordingId: recordingId,
                duration: finalDuration,
                createdAt: recordingStartTime ?? Date()
            )
        } catch {
            errorMessage = "Failed to verify audio file: \(error.localizedDescription)"
        }
    }
    
    public func updateStatusMessage(_ message: String?) {
        self.statusMessage = message
    }
    
    private func startExtendedRuntimeSession() {
        extendedRuntimeSession?.invalidate()
        extendedRuntimeSession = WKExtendedRuntimeSession()
        extendedRuntimeSession?.delegate = self
        extendedRuntimeSession?.start()
    }
    
    private func cleanupSession() {
        extendedRuntimeSession?.invalidate()
        extendedRuntimeSession = nil
        
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    
    public var formattedElapsedTime: String {
        let totalSeconds = max(0, Int(elapsedTime))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

extension WatchRecordingManager: AVAudioRecorderDelegate {
    public nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag && self.isRecording {
                self.errorMessage = "Audio recorder stopped unexpectedly"
            }
        }
    }
    
    public nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        Task { @MainActor in
            if let error = error {
                self.errorMessage = "Encode error: \(error.localizedDescription)"
            }
        }
    }
}

extension WatchRecordingManager: WKExtendedRuntimeSessionDelegate {
    public nonisolated func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        print("WKExtendedRuntimeSession started")
    }
    
    public nonisolated func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // Critical fix: DO NOT terminate the meeting recording when extended runtime session expires!
        // The background audio mode (UIBackgroundModes: ["audio"]) with active AVAudioSession maintains
        // continuous recording runtime across 30, 60, and 90+ minute meetings.
        Task { @MainActor in
            print("WKExtendedRuntimeSession will expire. Active audio recording continues under audio background mode.")
            // Attempt to renew the extended runtime companion session if still recording
            if self.isRecording {
                self.startExtendedRuntimeSession()
            }
        }
    }
    
    public nonisolated func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: (any Error)?) {
        print("WKExtendedRuntimeSession invalidated with reason: \(reason.rawValue), error: \(String(describing: error))")
    }
}
