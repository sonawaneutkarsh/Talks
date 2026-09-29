import SwiftUI

public struct ContentView: View {
    @ObservedObject var queueManager = JobQueueManager.shared
    @ObservedObject var connectivityManager = PhoneConnectivityManager.shared
    @State private var showingSettings = false
    @State private var jobPendingDeletion: MeetingJob?
    @State private var showDeleteConfirmation = false
    
    public init() {
        PipelineLogger.log(stage: "[LAUNCH] ContentView.init")
    }
    
    public var body: some View {
        let _ = PipelineLogger.log(stage: "[LAUNCH] ContentView.body evaluated")
        NavigationStack {
            List {
                // Status Header Card (strictly non-blocking, zero hit-testing interception)
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "applewatch")
                            .font(.title2)
                            .foregroundColor(connectivityManager.isPaired ? .green : .secondary)
                            .allowsHitTesting(false)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connectivityManager.isPaired ? "Apple Watch Connected" : "Apple Watch")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            if queueManager.isProcessing {
                                Text("Processing talks in queue...")
                                    .font(.caption2)
                                    .foregroundColor(.blue)
                            } else {
                                Text("Ready for new recordings")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .allowsHitTesting(false)
                        
                        Spacer()
                        
                        if queueManager.isProcessing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                                .scaleEffect(0.8)
                                .frame(width: 24, height: 24)
                                .allowsHitTesting(false)
                        }
                    }
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
                }
                
                // Recent Talks Section
                Section {
                    if queueManager.jobs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "waveform.circle")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                            
                            Text("No Talks Yet")
                                .font(.headline)
                            
                            Text("Tap Record on your Apple Watch to record a meeting. It will automatically transfer, transcribe, format with Apple Intelligence, and upload to Notion.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            
                            #if DEBUG
                            Button(action: {
                                SyntheticPipelineRunner.runSyntheticMeetingTest()
                            }) {
                                Text("Run Test Meeting Pipeline")
                                    .font(.footnote)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.purple)
                                    .padding(.top, 4)
                            }
                            #endif
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        ForEach(queueManager.jobs) { job in
                            NavigationLink(value: job.id) {
                                TalkRowView(job: job)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if job.status.isEligibleForDeletion {
                                    Button(role: .destructive) {
                                        jobPendingDeletion = job
                                        showDeleteConfirmation = true
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Recent Talks")
                }
            }
            .alert(
                "Delete Talk?",
                isPresented: $showDeleteConfirmation,
                presenting: jobPendingDeletion
            ) { job in
                Button("Cancel", role: .cancel) {
                    jobPendingDeletion = nil
                }
                Button("Delete", role: .destructive) {
                    queueManager.deleteJob(id: job.id)
                    jobPendingDeletion = nil
                }
            } message: { _ in
                Text("This removes the recording and local copy from this iPhone.\nYour Notion page will not be deleted.")
            }
            .navigationTitle("Talks")
            .navigationDestination(for: UUID.self) { jobId in
                if let job = queueManager.jobs.first(where: { $0.id == jobId }) {
                    TalkDetailView(job: job)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        PipelineLogger.log(stage: "[UI] Settings tapped")
                        showingSettings = true
                    }) {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .onAppear {
                PipelineLogger.log(stage: "[LAUNCH] first onAppear")
                PipelineLogger.log(stage: "[LAUNCH] root UI first frame reached")
            }
            .task {
                PipelineLogger.log(stage: "[LAUNCH] first .task entered")
                // Kick off queue processing only AFTER first UI frame is rendered
                queueManager.startProcessingQueue()
            }
            .refreshable {
                queueManager.startProcessingQueue()
            }
        }
    }
}

struct TalkRowView: View {
    let job: MeetingJob
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                statusPill(job.status)
            }
            
            HStack {
                Text(formatDate(job.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if job.duration > 0 {
                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatDuration(job.duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if job.notionPageUrl != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func statusPill(_ status: JobStatus) -> some View {
        HStack(spacing: 4) {
            if status == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Saved")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            } else {
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 6, height: 6)
                Text(status.displayText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor(status))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(status == .completed ? Color(UIColor.tertiarySystemFill) : statusColor(status).opacity(0.12))
        .cornerRadius(6)
    }
    
    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .waitingForTransfer, .received: return .orange
        case .transcribing: return .purple
        case .waitingForAI, .formatting: return .indigo
        case .waitingForNotion, .uploadingToNotion: return .blue
        case .completed: return .secondary
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
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
