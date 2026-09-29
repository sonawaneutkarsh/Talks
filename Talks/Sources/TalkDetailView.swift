import SwiftUI

public struct TalkDetailView: View {
    public let job: MeetingJob
    @ObservedObject var queueManager = JobQueueManager.shared
    @State private var showRawTranscript = false
    
    public init(job: MeetingJob) {
        self.job = job
    }
    
    // Find live version of this job in queue manager
    private var currentJob: MeetingJob {
        queueManager.jobs.first(where: { $0.id == job.id }) ?? job
    }
    
    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                // 1. Title
                Text(currentJob.displayTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 4)
                
                // 2. Date, duration, status card
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(formatDate(currentJob.createdAt), systemImage: "calendar")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if currentJob.duration > 0 {
                            Spacer()
                            Label(formatDuration(currentJob.duration), systemImage: "clock")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    HStack {
                        statusBadge(currentJob.status)
                        
                        Spacer()
                        
                        // 3. One-tap button to open in Notion if uploaded
                        if let urlString = currentJob.notionPageUrl, let url = URL(string: urlString) {
                            Link(destination: url) {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.up.right.square")
                                    Text("Open in Notion")
                                }
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                            }
                        }
                    }
                    
                    if let err = currentJob.errorMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                            
                            Button(action: {
                                queueManager.retryJob(id: currentJob.id)
                            }) {
                                Text("Retry Now")
                                    .font(.footnote)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .cornerRadius(8)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                
                // 4. Formatted Sections:
                // - Formatted Transcript
                VStack(alignment: .leading, spacing: 8) {
                    Label("AI-Formatted Transcript", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundColor(.purple)
                    
                    if let formatted = currentJob.aiFormattedTranscript {
                        Text(formatted)
                            .font(.body)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    } else {
                        Text("Transcript will appear here once Apple Intelligence processes the audio.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                
                // - Summary
                if let intelligence = currentJob.intelligence, !intelligence.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Summary", systemImage: "doc.text")
                            .font(.headline)
                            .foregroundColor(.blue)
                        
                        Text(intelligence.summary)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                // - Key Points
                if let intelligence = currentJob.intelligence, !intelligence.keyPoints.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Key Points", systemImage: "lightbulb")
                            .font(.headline)
                            .foregroundColor(.orange)
                        
                        ForEach(intelligence.keyPoints, id: \.self) { point in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .fontWeight(.bold)
                                Text(point)
                            }
                            .font(.body)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                // - Decisions
                if let intelligence = currentJob.intelligence, !intelligence.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Decisions", systemImage: "checkmark.seal")
                            .font(.headline)
                            .foregroundColor(.green)
                        
                        ForEach(intelligence.decisions, id: \.self) { dec in
                            HStack(alignment: .top, spacing: 6) {
                                Text("✓")
                                    .fontWeight(.bold)
                                    .foregroundColor(.green)
                                Text(dec)
                            }
                            .font(.body)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                // - Action Items
                if let intelligence = currentJob.intelligence, !intelligence.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Action Items", systemImage: "checklist")
                            .font(.headline)
                            .foregroundColor(.indigo)
                        
                        ForEach(intelligence.actionItems, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "square")
                                    .foregroundColor(.secondary)
                                Text(item)
                            }
                            .font(.body)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                // - Follow-Ups
                if let intelligence = currentJob.intelligence, !intelligence.followUps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Follow-Ups", systemImage: "questionmark.circle")
                            .font(.headline)
                            .foregroundColor(.teal)
                        
                        ForEach(intelligence.followUps, id: \.self) { fu in
                            HStack(alignment: .top, spacing: 6) {
                                Text("?")
                                    .fontWeight(.bold)
                                    .foregroundColor(.teal)
                                Text(fu)
                            }
                            .font(.body)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(12)
                }
                
                Divider()
                    .padding(.vertical, 4)
                
                // 5. Collapsible/bottom section for raw untouched transcript
                VStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup(isExpanded: $showRawTranscript) {
                        if let raw = currentJob.rawTranscript {
                            Text(raw)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        } else {
                            Text("No raw transcript available yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "waveform")
                            Text("Raw Untouched Transcript")
                                .font(.headline)
                        }
                        .foregroundColor(.primary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }
    
    @ViewBuilder
    private func statusBadge(_ status: JobStatus) -> some View {
        HStack(spacing: 4) {
            if status == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Saved to Notion")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            } else {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 7, height: 7)
                Text(status.displayText)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor(status))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(status == .completed ? Color(UIColor.tertiarySystemFill) : statusColor(status).opacity(0.14))
        .cornerRadius(8)
    }
    
    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .completed: return .secondary
        case .formatting, .transcribing, .uploadingToNotion: return .blue
        case .waitingForTransfer, .received: return .orange
        case .waitingForAI, .waitingForNotion: return .purple
        case .failed: return .red
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return "\(mins)m \(secs)s"
    }
}
