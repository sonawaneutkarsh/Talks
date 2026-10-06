import Foundation
import AVFoundation

public enum SyntheticPipelineRunner {
    public static let sampleRawTranscript = """
    Professor: So, let's review the ADR research planning. For the anomaly detection pipeline, we need to compare the autoencoder reconstruction loss against the isolation forest baseline on the synthetic telemetry dataset.
    
    Student: Right, um, I was wondering, um, if we should also include the Mahalanobis distance metric or if that's, like, overkill for the initial paper draft?
    
    Professor: That's a good question. Let's start with just the autoencoder and baseline first. If we have time before the October 15 submission deadline, we can add Mahalanobis. Also, make sure to write down the mathematical formulation of the loss function in section 3.
    
    Student: Sounds good. I will, um, implement the benchmark script by this Friday, October 2nd, and share the wandb dashboard link with you.
    
    Professor: Perfect. And for our next meeting on Monday at 2 PM, please have the preliminary ROC curves ready. If you run into CUDA memory issues on the cluster, ask the cluster admins for node allocation.
    """
    
    /// Generates a valid test M4A audio file containing a pure tone or silence,
    /// so the full audio file pipeline (AVAudioFile -> SpeechAnalyzer -> Notion) can be verified on device or simulator.
    public static func createTestAudioFile(at url: URL, durationSeconds: Double = 3.0) throws {
        let sampleRate: Double = 24000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "SyntheticAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM buffer"])
        }
        pcmBuffer.frameLength = frameCount
        
        let channels = pcmBuffer.floatChannelData!
        let channel = channels[0]
        let frequency: Float = 440.0 // 440 Hz standard tone
        for frame in 0..<Int(frameCount) {
            let sample = sin(Float(frame) * 2.0 * Float.pi * frequency / Float(sampleRate)) * 0.2
            channel[frame] = sample
        }
        
        let settings = TalksConstants.Audio.recordingSettings
        let audioFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try audioFile.write(from: pcmBuffer)
    }
    
    /// Enqueues a synthetic test meeting with sample meeting transcript directly into the queue.
    @MainActor
    public static func runSyntheticMeetingTest() {
        let meetingId = UUID()
        let job = MeetingJob(
            id: meetingId,
            createdAt: Date(),
            duration: 184.0,
            localAudioRelativePath: nil,
            rawTranscript: sampleRawTranscript, // Invariant: unedited raw transcript
            status: .waitingForAI
        )
        JobQueueManager.shared.addSyntheticMeeting(job: job)
    }
}
