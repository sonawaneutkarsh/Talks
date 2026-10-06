import Foundation
import WatchConnectivity

// MARK: - Architectural Invariant: Watch -> iPhone Ingestion Boundary
// 1. Out-of-Process Transfer: Audio is received via WCSessionDelegate.session(_:didReceive:).
// 2. Atomic Persistence: Files are moved immediately from temporary location to
//    Documents/Recordings/<uuid>.m4a before acknowledging.
// 3. Durable Acknowledgement: iPhone sends an ACK back to the Watch via transferUserInfo
//    (guaranteed background delivery even if the Watch app is suspended).
// 4. Queue Enqueue: Once persisted, the recording is immediately registered in JobQueueManager.

@MainActor
public final class PhoneConnectivityManager: NSObject, ObservableObject {
    public static let shared = PhoneConnectivityManager()
    
    @Published public private(set) var activationState: String = "notActivated"
    @Published public private(set) var isWatchAppInstalled = false
    @Published public private(set) var isPaired = false
    @Published public private(set) var isReachable = false
    @Published public private(set) var lastReceivedRecordingId: UUID?
    @Published public private(set) var lastReceivedFileSize: UInt64 = 0
    @Published public private(set) var lastDestinationPath: String?
    @Published public private(set) var lastEnqueueSuccess = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var lastPingStatus: String?
    @Published public private(set) var diagnosticLogs: [String] = []
    
    private var session: WCSession?
    private let recordingsDirectory: URL
    private let queueManager: JobQueueManager
    
    public override convenience init() {
        self.init(queueManager: .shared, activateSession: true)
    }
    
    /// - Parameters:
    ///   - queueManager: Queue that receives incoming recordings.
    ///   - activateSession: Activate `WCSession.default`. Unit tests pass `false` so no real
    ///     WatchConnectivity session (and no paired-Watch state) is involved.
    public init(queueManager: JobQueueManager, activateSession: Bool) {
        PipelineLogger.log(stage: "[LAUNCH] WCSession manager init ENTER")
        self.queueManager = queueManager
        self.recordingsDirectory = queueManager.recordingsDirectory
        super.init()
        
        createRecordingsDirectoryIfNeeded()
        if activateSession {
            setupWatchConnectivity()
        }
        PipelineLogger.log(stage: "[LAUNCH] WCSession manager init EXIT")
    }
    
    public func logEvent(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        
        diagnosticLogs.insert(entry, at: 0)
        if diagnosticLogs.count > 60 {
            diagnosticLogs.removeLast()
        }
        print("[Phone WCSession] \(message)")
    }
    
    public func clearLogs() {
        diagnosticLogs.removeAll()
    }
    
    private func createRecordingsDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: recordingsDirectory.path) {
            do {
                try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
                logEvent("Created recordings directory at \(recordingsDirectory.lastPathComponent)")
            } catch {
                logEvent("ERROR creating recordings directory: \(error.localizedDescription)")
            }
        }
    }
    
    public func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            activationState = "Unsupported"
            logEvent("ERROR: WCSession is not supported on this device.")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        self.activationState = "activating"
        logEvent("setupWatchConnectivity called. activate() dispatched. Initial state: activating")
    }
    
    public func reactivateSession() {
        guard let session = session else {
            setupWatchConnectivity()
            return
        }
        logEvent("Manually requesting session.activate()...")
        self.activationState = "activating"
        session.activate()
    }
    
    public func updateDiagnosticState(
        activationState: WCSessionActivationState,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        isReachable: Bool
    ) {
        let stateStr: String
        switch activationState {
        case .activated: stateStr = "activated"
        case .inactive: stateStr = "inactive"
        case .notActivated: stateStr = "notActivated"
        @unknown default: stateStr = "unknown(\(activationState.rawValue))"
        }
        
        self.activationState = stateStr
        self.isPaired = isPaired
        self.isWatchAppInstalled = isWatchAppInstalled
        self.isReachable = isReachable
    }
    
#if DEBUG
    public func sendPingToWatch() {
        guard let session = session else {
            lastPingStatus = "WCSession is nil"
            logEvent("Ping Watch error: WCSession is nil")
            return
        }
        guard session.isPaired else {
            lastPingStatus = "Watch not paired"
            logEvent("Ping Watch error: Apple Watch is not paired")
            return
        }
        guard session.isWatchAppInstalled else {
            lastPingStatus = "Watch app not installed"
            logEvent("Ping Watch error: Talks Watch app is not installed on paired watch")
            return
        }
        guard session.isReachable else {
            lastPingStatus = "Watch unreachable (screen off or app closed)"
            logEvent("Ping Watch note: Watch is not currently reachable for live messaging. WCSession reachable=false.")
            return
        }
        
        lastPingStatus = "Pinging Watch..."
        logEvent("Sending live ping to Watch...")
        session.sendMessage(["type": "ping", "timestamp": Date().timeIntervalSince1970], replyHandler: { reply in
            Task { @MainActor in
                let response = reply["response"] as? String ?? "OK"
                let device = reply["device"] as? String ?? "Watch"
                self.lastPingStatus = "\(device) replied: \(response) ✓"
                self.logEvent("Ping SUCCESS from \(device): \(response)")
            }
        }, errorHandler: { error in
            Task { @MainActor in
                self.lastPingStatus = "Ping error: \(error.localizedDescription)"
                self.logEvent("Ping ERROR from Watch: \(error.localizedDescription)")
            }
        })
    }
#endif
    
    public func sendAckToWatch(recordingId: UUID) {
        guard let session = session, session.activationState == .activated else {
            logEvent("sendAck skipped: session not activated")
            return
        }
        let payload = [TalksConstants.TransferKeys.ackId: recordingId.uuidString]
        
        // Queue durable background userInfo transfer guaranteed to deliver across app suspension and state changes
        session.transferUserInfo(payload)
        logEvent("Durable transferUserInfo ACK queued for Watch recording: \(recordingId.uuidString.prefix(8))")
    }
    
    public func handleReceivedRecording(id: UUID, createdAt: Date, duration: TimeInterval, relativeAudioPath: String) {
        lastReceivedRecordingId = id
        
        logEvent("Calling JobQueueManager.enqueueReceivedRecording for \(id.uuidString.prefix(8))...")
        // Persist and enqueue first
        queueManager.enqueueReceivedRecording(
            id: id,
            createdAt: createdAt,
            duration: duration,
            relativeAudioPath: relativeAudioPath
        )
        lastEnqueueSuccess = true
        logEvent("JobQueueManager.enqueueReceivedRecording SUCCEEDED for \(id.uuidString.prefix(8)) ✓")
        
        // Send ACK back only after durable persistence on iPhone
        sendAckToWatch(recordingId: id)
    }
}

extension PhoneConnectivityManager: WCSessionDelegate {
    public nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let errDesc = error?.localizedDescription
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        
        Task { @MainActor in
            self.updateDiagnosticState(
                activationState: activationState,
                isPaired: paired,
                isWatchAppInstalled: installed,
                isReachable: reachable
            )
            if let err = errDesc {
                self.lastError = "Activation: \(err)"
                self.logEvent("activationDidCompleteWith ERROR: \(err)")
            } else {
                self.lastError = nil
                self.logEvent("activationDidCompleteWith: \(self.activationState). paired=\(paired), watchAppInstalled=\(installed), reachable=\(reachable)")
            }
        }
    }
    
    public nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        let state = session.activationState
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        
        Task { @MainActor in
            self.logEvent("sessionDidBecomeInactive called")
            self.updateDiagnosticState(
                activationState: state,
                isPaired: paired,
                isWatchAppInstalled: installed,
                isReachable: reachable
            )
        }
    }
    
    public nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
        let state = session.activationState
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        
        Task { @MainActor in
            self.logEvent("sessionDidDeactivate called -> re-activating WCSession.default")
            self.updateDiagnosticState(
                activationState: state,
                isPaired: paired,
                isWatchAppInstalled: installed,
                isReachable: reachable
            )
        }
    }
    
    public nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        let state = session.activationState
        let paired = session.isPaired
        let installed = session.isWatchAppInstalled
        let reachable = session.isReachable
        
        Task { @MainActor in
            self.updateDiagnosticState(
                activationState: state,
                isPaired: paired,
                isWatchAppInstalled: installed,
                isReachable: reachable
            )
            self.logEvent("sessionWatchStateDidChange: paired=\(paired), watchAppInstalled=\(installed)")
        }
    }
    
    public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isReachable = reachable
            self.logEvent("sessionReachabilityDidChange: reachable=\(reachable)")
        }
    }
    
    public nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let tempURL = file.fileURL
        let tempName = tempURL.lastPathComponent
        let metadataSummary = metadata.description
        let idString = metadata[TalksConstants.TransferKeys.recordingId] as? String
        let createdAtTimeInterval = metadata[TalksConstants.TransferKeys.createdAt] as? TimeInterval ?? Date().timeIntervalSince1970
        let duration = metadata[TalksConstants.TransferKeys.duration] as? TimeInterval ?? 0
        
        Task { @MainActor in
            PhoneConnectivityManager.shared.logEvent(">>> session(_:didReceive:) file received from Watch! Temp: \(tempName)")
            PhoneConnectivityManager.shared.logEvent("Metadata received: \(metadataSummary)")
        }
        
        guard let idStr = idString, let recordingId = UUID(uuidString: idStr) else {
            Task { @MainActor in
                let err = "Received WCSessionFile without valid recordingId in metadata: \(metadataSummary)"
                PhoneConnectivityManager.shared.lastError = err
                PhoneConnectivityManager.shared.logEvent("ERROR: \(err)")
            }
            return
        }
        
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        let destinationFilename = "\(recordingId.uuidString).m4a"
        let destinationURL = dir.appendingPathComponent(destinationFilename)
        let createdAt = Date(timeIntervalSince1970: createdAtTimeInterval)
        
        do {
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            // Move item to destination; if cross-volume error occurs, fallback to copyItem
            do {
                try FileManager.default.moveItem(at: tempURL, to: destinationURL)
            } catch {
                try FileManager.default.copyItem(at: tempURL, to: destinationURL)
            }
            
            // Verify file size of the moved/copied file
            let attrs = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let size = attrs[.size] as? UInt64 ?? 0
            guard size > 0 else {
                let err = "Received zero-length file for recording \(recordingId). Rejecting."
                try? FileManager.default.removeItem(at: destinationURL)
                Task { @MainActor in
                    PhoneConnectivityManager.shared.lastError = err
                    PhoneConnectivityManager.shared.logEvent("ERROR: \(err)")
                }
                return
            }
            
            Task { @MainActor in
                PhoneConnectivityManager.shared.lastReceivedRecordingId = recordingId
                PhoneConnectivityManager.shared.lastReceivedFileSize = size
                PhoneConnectivityManager.shared.lastDestinationPath = destinationFilename
                PhoneConnectivityManager.shared.lastError = nil
                PhoneConnectivityManager.shared.logEvent("SUCCESS: Saved incoming recording (\(size) bytes) to Documents/Recordings/\(destinationFilename)")
                
                PhoneConnectivityManager.shared.handleReceivedRecording(
                    id: recordingId,
                    createdAt: createdAt,
                    duration: duration,
                    relativeAudioPath: destinationFilename
                )
            }
        } catch {
            let err = "Failed to save incoming WCSession file: \(error.localizedDescription)"
            Task { @MainActor in
                PhoneConnectivityManager.shared.lastError = err
                PhoneConnectivityManager.shared.logEvent("ERROR: \(err)")
            }
        }
    }
    
    // Live interactive message handler
    public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let isPing = (message["type"] as? String) == "ping"
        let msgDesc = message.description
        Task { @MainActor in
            PhoneConnectivityManager.shared.logEvent("didReceiveMessage with replyHandler: \(msgDesc)")
        }
        if isPing {
            replyHandler(["response": "pong", "device": "iPhone"])
        } else {
            replyHandler(["status": "received"])
        }
    }
    
    public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let msgDesc = message.description
        Task { @MainActor in
            PhoneConnectivityManager.shared.logEvent("didReceiveMessage: \(msgDesc)")
        }
    }
    
    public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let infoDesc = userInfo.description
        Task { @MainActor in
            PhoneConnectivityManager.shared.logEvent("didReceiveUserInfo: \(infoDesc)")
        }
    }
    
    public nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let errDesc = error?.localizedDescription
        Task { @MainActor in
            if let err = errDesc {
                PhoneConnectivityManager.shared.logEvent("Phone-side didFinish fileTransfer with error: \(err)")
            } else {
                PhoneConnectivityManager.shared.logEvent("Phone-side didFinish fileTransfer finished.")
            }
        }
    }
}
