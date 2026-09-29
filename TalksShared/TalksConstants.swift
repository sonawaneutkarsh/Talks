import Foundation
import AVFoundation

public enum TalksConstants {
    public static let appName = "Talks"
    
    // WatchConnectivity Message & Metadata Keys
    public enum TransferKeys {
        public static let recordingId = "recordingId"
        public static let createdAt = "createdAt"
        public static let duration = "duration"
        public static let sampleRate = "sampleRate"
        public static let format = "m4a"
        public static let ackId = "ackId"
    }
    
    // Audio Configuration
    public enum Audio {
        public static let sampleRate: Double = 24000.0
        public static let numberOfChannels: Int = 1
        public static let bitRate: Int = 32000
        
        public static var recordingSettings: [String: Any] {
            [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: numberOfChannels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: bitRate
            ]
        }
    }
    
    // Keychain Keys
    public enum KeychainKeys {
        public static let notionApiKey = "com.personal.talks.notionApiKey"
        public static let notionParentPageId = "com.personal.talks.notionParentPageId"
        public static let notionTalksPageId = "com.personal.talks.notionTalksPageId"
    }
}
