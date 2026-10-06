import Foundation

/// One Watch recording that was handed to `WCSession.transferFile` and is waiting for the iPhone's ACK.
public struct WatchTransferRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let duration: TimeInterval
    public let fileRelativePath: String
    public var isTransferred: Bool
    public var isAcknowledgedByPhone: Bool

    public init(
        id: UUID,
        createdAt: Date,
        duration: TimeInterval,
        fileRelativePath: String,
        isTransferred: Bool = false,
        isAcknowledgedByPhone: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.fileRelativePath = fileRelativePath
        self.isTransferred = isTransferred
        self.isAcknowledgedByPhone = isAcknowledgedByPhone
    }
}

/// Persistent ledger of Watch -> iPhone transfers.
///
/// The Watch deletes a local recording only when the iPhone acknowledges that exact recording ID.
/// The logic lives in TalksShared (not the watchOS target) so the iOS unit-test bundle can exercise it
/// against real files on the simulator.
public struct WatchTransferLedger: Sendable {
    public enum AckOutcome: Equatable, Sendable {
        /// The ACK did not match any tracked recording. Nothing was deleted.
        case untracked
        /// The ACK matched; the record is marked acknowledged and the local audio file was removed.
        case acknowledgedAndDeleted
        /// The ACK matched, but the local audio file was already gone.
        case acknowledgedFileAlreadyMissing
        /// The ACK matched, but removing the local audio file failed. The record stays acknowledged.
        case acknowledgedDeleteFailed(String)
    }

    public private(set) var records: [WatchTransferRecord]
    public let registryURL: URL
    public let recordingsDirectory: URL

    /// Loads the ledger from `registryURL`. A missing or unreadable registry yields an empty ledger.
    public init(registryURL: URL, recordingsDirectory: URL) {
        self.registryURL = registryURL
        self.recordingsDirectory = recordingsDirectory
        if let data = try? Data(contentsOf: registryURL),
           let decoded = try? JSONDecoder().decode([WatchTransferRecord].self, from: data) {
            self.records = decoded
        } else {
            self.records = []
        }
    }

    public var pendingRecords: [WatchTransferRecord] {
        records.filter { !$0.isAcknowledgedByPhone }
    }

    /// Adds (or replaces) a record and persists the ledger atomically.
    public mutating func track(_ record: WatchTransferRecord) {
        records.removeAll { $0.id == record.id }
        records.append(record)
        save()
    }

    /// Applies an ACK from the iPhone. Only a matching recording ID can delete local audio.
    @discardableResult
    public mutating func acknowledge(recordingId: UUID) -> AckOutcome {
        guard let index = records.firstIndex(where: { $0.id == recordingId }) else {
            return .untracked
        }

        records[index].isAcknowledgedByPhone = true
        records[index].isTransferred = true
        save()

        let fileURL = recordingsDirectory.appendingPathComponent(records[index].fileRelativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .acknowledgedFileAlreadyMissing
        }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return .acknowledgedAndDeleted
        } catch {
            return .acknowledgedDeleteFailed(error.localizedDescription)
        }
    }

    public func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: registryURL, options: .atomic)
        } catch {
            PipelineLogger.log(stage: "watch ledger save failed", details: error.localizedDescription)
        }
    }
}
