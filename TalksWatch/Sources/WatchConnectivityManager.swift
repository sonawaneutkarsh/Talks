import Foundation
import WatchConnectivity
import WatchKit

// MARK: - Architectural Invariant: WatchConnectivity Transfer Pipeline
// 1. Out-of-Process Transfer: WCSession.transferFile delegates actual transmission to the wcd daemon.
//    Transfers complete even after the app is suspended or the user leaves the app.
// 2. Persistent Transfer Ledger: Pending transfers are stored in Documents/watch_transfers.json.
// 3. Verified ACK Deletion: Local recordings are removed only after the phone sends a verified ACK
//    via transferUserInfo or didReceiveMessage.
// 4. Zero Main-Thread Blocking: All WCSession interactions and callbacks are non-blocking and asynchronous.

public struct WatchTransferRecord: Codable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let duration: TimeInterval
    public let fileRelativePath: String
    public var isTransferred: Bool
    public var isAcknowledgedByPhone: Bool
}

public struct WatchDiagnosticsInfo: Equatable {
    public var recordingId: String = "None"
    public var activationState: String = "notActivated"
    public var isCompanionAppInstalled: Bool = false
    public var isReachable: Bool = false
    public var transferFileCalled: Bool = false
    public var outstandingTransfersCount: Int = 0
    public var fileURL: String = "None"
    public var fileSize: UInt64 = 0
    public var lastError: String? = nil
    public var lastAckReceived: String? = nil
    public var lastPingStatus: String? = nil
}

@MainActor
public final class WatchConnectivityManager: NSObject, ObservableObject {
    public static let shared = WatchConnectivityManager()
    
    @Published public private(set) var isConnectedToPhone = false
    @Published public private(set) var activeTransfersCount = 0
    @Published public private(set) var transferStatusMessage = "Ready"
    @Published public private(set) var pendingRecords: [WatchTransferRecord] = []
    @Published public private(set) var diagnostics = WatchDiagnosticsInfo()
    @Published public private(set) var isPinging = false
    
    private var session: WCSession?
    private let registryURL: URL
    
    public override init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.registryURL = docs.appendingPathComponent("watch_transfers.json")
        super.init()
        
        loadRecords()
        setupWatchConnectivity()
    }
    
    public func setupWatchConnectivity() {
        guard WCSession.isSupported() else {
            transferStatusMessage = "WatchConnectivity unsupported"
            diagnostics.activationState = "Unsupported"
            print("[Watch WCSession] WCSession is not supported on this device.")
            return
        }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
        diagnostics.activationState = "activating"
        print("[Watch WCSession] Session setup initiated, activation dispatched. Initial state: activating")
    }
    
    public func updateDiagnosticState(
        activationState: WCSessionActivationState,
        isCompanionAppInstalled: Bool,
        isReachable: Bool,
        outstandingTransfersCount: Int
    ) {
        let stateStr: String
        switch activationState {
        case .activated: stateStr = "activated"
        case .inactive: stateStr = "inactive"
        case .notActivated: stateStr = "notActivated"
        @unknown default: stateStr = "unknown(\(activationState.rawValue))"
        }
        
        diagnostics.activationState = stateStr
        diagnostics.isCompanionAppInstalled = isCompanionAppInstalled
        diagnostics.isReachable = isReachable
        diagnostics.outstandingTransfersCount = outstandingTransfersCount
        activeTransfersCount = outstandingTransfersCount
        isConnectedToPhone = (activationState == .activated && isReachable)
    }
    
    private func loadRecords() {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return }
        do {
            let data = try Data(contentsOf: registryURL)
            let records = try JSONDecoder().decode([WatchTransferRecord].self, from: data)
            self.pendingRecords = records
        } catch {
            print("[Watch WCSession] Failed to load watch transfers registry: \(error)")
        }
    }
    
    private func saveRecords() {
        do {
            let data = try JSONEncoder().encode(pendingRecords)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            print("[Watch WCSession] Failed to save watch transfers registry: \(error)")
        }
    }
    
    public func queueFileForTransfer(fileURL: URL, recordingId: UUID, duration: TimeInterval, createdAt: Date) {
        let relativePath = fileURL.lastPathComponent
        let record = WatchTransferRecord(
            id: recordingId,
            createdAt: createdAt,
            duration: duration,
            fileRelativePath: relativePath,
            isTransferred: false,
            isAcknowledgedByPhone: false
        )
        
        pendingRecords.removeAll { $0.id == recordingId }
        pendingRecords.append(record)
        saveRecords()
        
        transferStatusMessage = "Transferring to iPhone..."
        performFileTransfer(record: record, fileURL: fileURL, force: false)
    }
    
    public func performFileTransfer(record: WatchTransferRecord, fileURL: URL, force: Bool = false) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attrs?[.size] as? UInt64 ?? 0
        
        diagnostics.recordingId = record.id.uuidString
        diagnostics.fileURL = fileURL.lastPathComponent
        diagnostics.fileSize = fileSize
        
        guard let session = session else {
            transferStatusMessage = "WCSession not initialized"
            diagnostics.lastError = "WCSession instance is nil"
            print("[Watch WCSession] Error: session is nil")
            return
        }
        
        let currentTransfers = session.outstandingFileTransfers
        let count = currentTransfers.count
        
        updateDiagnosticState(
            activationState: session.activationState,
            isCompanionAppInstalled: session.isCompanionAppInstalled,
            isReachable: session.isReachable,
            outstandingTransfersCount: count
        )
        
        guard session.activationState == .activated else {
            transferStatusMessage = "Queued (Activating WCSession...)"
            diagnostics.lastError = "Session not activated (state: \(diagnostics.activationState))"
            print("[Watch WCSession] Session not activated yet. Calling activate().")
            session.activate()
            return
        }
        
        // Prevent duplicate transfers in the WCSession daemon queue unless forced
        let matchingTransfers = currentTransfers.filter { transfer in
            if let idStr = transfer.file.metadata?[TalksConstants.TransferKeys.recordingId] as? String {
                return idStr == record.id.uuidString
            }
            return false
        }
        
        if !matchingTransfers.isEmpty && !force {
            transferStatusMessage = "In daemon transfer queue..."
            diagnostics.transferFileCalled = true
            diagnostics.outstandingTransfersCount = count
            print("[Watch WCSession] Transfer for \(record.id.uuidString) already in queue (\(matchingTransfers.count) existing). Total outstanding: \(count)")
            return
        }
        
        // If forced retry, cancel old stalled transfers for this ID
        if force {
            for oldTransfer in matchingTransfers {
                print("[Watch WCSession] Cancelling existing stalled transfer for \(record.id.uuidString)")
                oldTransfer.cancel()
            }
        }
        
        let metadata: [String: Any] = [
            TalksConstants.TransferKeys.recordingId: record.id.uuidString,
            TalksConstants.TransferKeys.createdAt: record.createdAt.timeIntervalSince1970,
            TalksConstants.TransferKeys.duration: record.duration,
            TalksConstants.TransferKeys.sampleRate: TalksConstants.Audio.sampleRate
        ]
        
        _ = session.transferFile(fileURL, metadata: metadata)
        diagnostics.transferFileCalled = true
        diagnostics.outstandingTransfersCount = count + 1
        diagnostics.lastError = nil
        activeTransfersCount = count + 1
        transferStatusMessage = "transferFile() called -> daemon queue (\(activeTransfersCount))"
        print("[Watch WCSession] transferFile() invoked successfully for \(record.id.uuidString). File: \(fileURL.lastPathComponent), Size: \(fileSize) bytes. Total outstanding transfers: \(activeTransfersCount)")
    }
    
    public func retryPendingTransfers(force: Bool = false) {
        guard let session = session, session.activationState == .activated else {
            session?.activate()
            return
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("WatchRecordings", isDirectory: true)
        
        for record in pendingRecords where !record.isAcknowledgedByPhone {
            let fileURL = dir.appendingPathComponent(record.fileRelativePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                performFileTransfer(record: record, fileURL: fileURL, force: force)
            }
        }
    }
    
#if DEBUG
    public func sendPingToPhone() {
        print("[Watch WCSession] [PING] Ping button tapped. isMainThread=\(Thread.isMainThread)")
        
        guard !isPinging else {
            print("[Watch WCSession] [PING] Ping already in progress. Ignoring duplicate tap. isMainThread=\(Thread.isMainThread)")
            return
        }
        
        guard let session = session else {
            diagnostics.lastPingStatus = "WCSession is nil"
            print("[Watch WCSession] [PING] WCSession is nil.")
            return
        }
        
        guard session.activationState == .activated else {
            diagnostics.lastPingStatus = "Session not activated"
            print("[Watch WCSession] [PING] Session not activated: \(session.activationState.rawValue)")
            return
        }
        
        guard session.isReachable else {
            diagnostics.lastPingStatus = "Phone unreachable (Locked or Out of Range)"
            print("[Watch WCSession] [PING] Phone is not reachable right now. isMainThread=\(Thread.isMainThread)")
            return
        }
        
        isPinging = true
        diagnostics.lastPingStatus = "Pinging iPhone..."
        print("[Watch WCSession] [PING] Marked isPinging=true, diagnostics updated. isMainThread=\(Thread.isMainThread)")
        
        // Dispatch session.sendMessage fully asynchronously off the main thread
        // to guarantee that Mach port IPC to wcd never blocks the Watch UI
        let messagePayload: [String: Any] = [
            "type": "ping",
            "timestamp": Date().timeIntervalSince1970
        ]
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak session] in
            guard let session = session else {
                Task { @MainActor [weak self] in
                    self?.isPinging = false
                    self?.diagnostics.lastPingStatus = "Session deallocated"
                }
                return
            }
            
            print("[Watch WCSession] [PING] sendMessage called on background thread. isMainThread=\(Thread.isMainThread)")
            
            session.sendMessage(messagePayload, replyHandler: { reply in
                let response = reply["response"] as? String ?? "OK"
                let isMain = Thread.isMainThread
                print("[Watch WCSession] [PING] reply handler invoked. isMainThread=\(isMain), response=\(response)")
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.isPinging = false
                    self.diagnostics.lastPingStatus = "Phone replied: \(response) ✓"
                    print("[Watch WCSession] [PING] main-thread state updated with SUCCESS. (on @MainActor)")
                }
            }, errorHandler: { error in
                let errDesc = error.localizedDescription
                let isMain = Thread.isMainThread
                print("[Watch WCSession] [PING] error handler invoked. isMainThread=\(isMain), error=\(errDesc)")
                
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.isPinging = false
                    self.diagnostics.lastPingStatus = "Ping failed: \(errDesc)"
                    print("[Watch WCSession] [PING] main-thread state updated with FAILURE. (on @MainActor)")
                }
            })
        }
    }
#endif
    
    public func handlePhoneAcknowledgement(recordingId: UUID) {
        guard let index = pendingRecords.firstIndex(where: { $0.id == recordingId }) else {
            print("[Watch WCSession] Received ACK for untracked recordingId: \(recordingId)")
            return
        }
        
        pendingRecords[index].isAcknowledgedByPhone = true
        pendingRecords[index].isTransferred = true
        saveRecords()
        
        diagnostics.lastAckReceived = "\(recordingId.uuidString.prefix(8)) ✓"
        transferStatusMessage = "Transferred & Verified by iPhone ✓"
        WatchRecordingManager.shared.updateStatusMessage("Sent ✓")
        
        // PRODUCTION BEHAVIOR: Delete local Watch audio only after durable ACK is confirmed
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileURL = docs.appendingPathComponent("WatchRecordings", isDirectory: true).appendingPathComponent(pendingRecords[index].fileRelativePath)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("[Watch WCSession] Phone ACK confirmed for \(fileURL.lastPathComponent). Safely removed local Watch copy.")
            } catch {
                print("[Watch WCSession] Error removing local recording after ACK: \(error.localizedDescription)")
            }
        }
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    public nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        let errDesc = error?.localizedDescription
        let isCompanion = session.isCompanionAppInstalled
        let isReachable = session.isReachable
        let count = session.outstandingFileTransfers.count
        let rawState = activationState.rawValue
        
        Task { @MainActor in
            self.updateDiagnosticState(
                activationState: activationState,
                isCompanionAppInstalled: isCompanion,
                isReachable: isReachable,
                outstandingTransfersCount: count
            )
            if let err = errDesc {
                self.diagnostics.lastError = "Activation failed: \(err)"
                print("[Watch WCSession] activationDidCompleteWith error: \(err)")
            } else {
                print("[Watch WCSession] activationDidCompleteWith: \(rawState). companionInstalled: \(isCompanion), reachable: \(isReachable)")
            }
            if activationState == .activated {
                self.retryPendingTransfers(force: false)
            }
        }
    }
    
    public nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let state = session.activationState
        let isCompanion = session.isCompanionAppInstalled
        let count = session.outstandingFileTransfers.count
        
        Task { @MainActor in
            self.updateDiagnosticState(
                activationState: state,
                isCompanionAppInstalled: isCompanion,
                isReachable: reachable,
                outstandingTransfersCount: count
            )
            print("[Watch WCSession] sessionReachabilityDidChange: \(reachable)")
        }
    }
    
    public nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        let remaining = session.outstandingFileTransfers.count
        let errorDescription = error?.localizedDescription
        let fileId = fileTransfer.file.metadata?[TalksConstants.TransferKeys.recordingId] as? String ?? "unknown"
        
        Task { @MainActor in
            self.activeTransfersCount = remaining
            self.diagnostics.outstandingTransfersCount = remaining
            
            if let err = errorDescription {
                self.diagnostics.lastError = "Transfer finish err: \(err)"
                self.transferStatusMessage = "Transfer daemon error: \(err)"
                print("[Watch WCSession] didFinish fileTransfer for \(fileId) with ERROR: \(err)")
            } else {
                self.diagnostics.lastError = nil
                self.transferStatusMessage = "Daemon delivered file to iPhone! Awaiting ACK..."
                print("[Watch WCSession] didFinish fileTransfer for \(fileId) SUCCESS! Out of process delivery finished. Remaining outstanding: \(remaining)")
            }
        }
    }
    
    // Live foreground message acknowledgement & ping responses
    public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let type = message["type"] as? String, type == "ping" {
            replyHandler(["response": "pong", "device": "Apple Watch"])
            return
        }
        
        if let ackString = message[TalksConstants.TransferKeys.ackId] as? String,
           let ackUUID = UUID(uuidString: ackString) {
            Task { @MainActor in
                self.handlePhoneAcknowledgement(recordingId: ackUUID)
            }
            replyHandler(["status": "acknowledged"])
            return
        }
        replyHandler(["status": "received"])
    }
    
    public nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let ackString = message[TalksConstants.TransferKeys.ackId] as? String,
           let ackUUID = UUID(uuidString: ackString) {
            Task { @MainActor in
                self.handlePhoneAcknowledgement(recordingId: ackUUID)
            }
        }
    }
    
    // Durable background userInfo acknowledgement (delivered even if watch was suspended)
    public nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let ackString = userInfo[TalksConstants.TransferKeys.ackId] as? String,
           let ackUUID = UUID(uuidString: ackString) {
            Task { @MainActor in
                self.handlePhoneAcknowledgement(recordingId: ackUUID)
            }
        }
    }
}
