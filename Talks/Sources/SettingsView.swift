import SwiftUI

public struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var queueManager = JobQueueManager.shared
    @ObservedObject var connectivityManager = PhoneConnectivityManager.shared
    
    @State private var apiKey: String = ""
    @State private var parentPageId: String = ""
    @State private var isTestingNotion = false
    @State private var notionStatusMessage: String?
    @State private var notionStatusColor: Color = .primary
    
    @State private var isSpeechAvailable: Bool = false
    @State private var aiStatus: (isAvailable: Bool, message: String) = (false, "Checking...")
    @State private var isDiagnosticsExpanded: Bool = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                // MARK: - 1. Notion Setup
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notion Integration Token")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("secret_...", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Parent Notion Page URL or ID")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Page URL or 32-character ID", text: $parentPageId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                    
                    Button(action: saveNotionCredentials) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                            Text("Save Credentials to Keychain")
                        }
                    }
                    
                    Button(action: testNotionConnection) {
                        HStack {
                            if isTestingNotion {
                                ProgressView()
                                    .padding(.trailing, 4)
                            } else {
                                Image(systemName: "link")
                            }
                            Text("Test Connection & Sync 'Talks' Page")
                        }
                    }
                    .disabled(isTestingNotion || apiKey.isEmpty || parentPageId.isEmpty)
                    
                    if let message = notionStatusMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(notionStatusColor)
                    }
                } header: {
                    Text("Notion Configuration")
                } footer: {
                    Text("Credentials are stored securely in your iPhone Keychain. Talks automatically creates and syncs meeting notes into a child page named 'Talks'.")
                }
                
                // MARK: - 2. On-Device Processing
                Section {
                    HStack {
                        Label("Speech Transcription", systemImage: "waveform")
                        Spacer()
                        if isSpeechAvailable {
                            Text("Ready (On-Device)")
                                .font(.footnote)
                                .foregroundColor(.green)
                        } else {
                            Text("Checking...")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label("Apple Intelligence", systemImage: "sparkles")
                            Spacer()
                            Text(aiStatus.isAvailable ? "Available" : "On-Device Fallback")
                                .font(.footnote)
                                .foregroundColor(aiStatus.isAvailable ? .green : .secondary)
                        }
                        Text(aiStatus.message)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Processing")
                } footer: {
                    Text("All speech transcription and AI formatting execute 100% locally on your iPhone using Apple's on-device frameworks ($0 recurring cost).")
                }
                
                // MARK: - 3. Apple Watch Companion
                Section {
                    HStack {
                        Label("Watch Paired", systemImage: "applewatch")
                        Spacer()
                        Text(connectivityManager.isPaired ? "Yes" : "No")
                            .font(.footnote)
                            .foregroundColor(connectivityManager.isPaired ? .green : .secondary)
                    }
                    
                    HStack {
                        Label("Watch App Installed", systemImage: "app.badge.checkmark")
                        Spacer()
                        Text(connectivityManager.isWatchAppInstalled ? "Yes" : "No")
                            .font(.footnote)
                            .foregroundColor(connectivityManager.isWatchAppInstalled ? .green : .secondary)
                    }
                    
                    HStack {
                        Label("Watch Reachability", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(connectivityManager.isReachable ? "Reachable" : "Standby / Background")
                            .font(.footnote)
                            .foregroundColor(connectivityManager.isReachable ? .green : .secondary)
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    Text("Recordings made on your Apple Watch automatically transfer to your iPhone via durable background sync when in range.")
                }
                
                // MARK: - 4. Advanced & Diagnostics
                Section {
                    DisclosureGroup(isExpanded: $isDiagnosticsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                GridRow {
                                    Text("WCSession:")
                                        .foregroundColor(.secondary)
                                    Text(connectivityManager.activationState)
                                        .fontWeight(.semibold)
                                        .foregroundColor(connectivityManager.activationState == "activated" ? .green : .orange)
                                }
                                
                                if let fileId = connectivityManager.lastReceivedRecordingId {
                                    GridRow {
                                        Text("Last File:")
                                            .foregroundColor(.secondary)
                                        Text("\(fileId.uuidString.prefix(8))... (\(connectivityManager.lastReceivedFileSize) B)")
                                            .font(.caption)
                                    }
                                }
                                
                                if let dest = connectivityManager.lastDestinationPath {
                                    GridRow {
                                        Text("Saved Path:")
                                            .foregroundColor(.secondary)
                                        Text(dest)
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                }
                                
                                GridRow {
                                    Text("Pipeline Enqueued:")
                                        .foregroundColor(.secondary)
                                    Text(connectivityManager.lastEnqueueSuccess ? "YES ✓" : "None yet")
                                        .foregroundColor(connectivityManager.lastEnqueueSuccess ? .green : .secondary)
                                }
                            }
                            .font(.caption)
                            .padding(.vertical, 4)
                            
                            if let err = connectivityManager.lastError {
                                Text("Last Error: \(err)")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(4)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            
                            HStack(spacing: 8) {
                                Button(action: {
                                    connectivityManager.reactivateSession()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                        Text("Reactivate Session")
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                
                                Button(action: {
                                    connectivityManager.clearLogs()
                                }) {
                                    Text("Clear Logs")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.top, 4)
                            
                            // Event Log Preview
                            VStack(alignment: .leading, spacing: 2) {
                                Text("WCSESSION EVENT LOG")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                                
                                if connectivityManager.diagnosticLogs.isEmpty {
                                    Text("No events logged.")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(Array(connectivityManager.diagnosticLogs.prefix(5).enumerated()), id: \.offset) { _, entry in
                                            Text(entry)
                                                .font(.system(size: 9, design: .monospaced))
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(6)
                                    .background(Color(UIColor.tertiarySystemFill))
                                    .cornerRadius(6)
                                }
                            }
                            .padding(.top, 4)
                        }
                    } label: {
                        Label("Connectivity Diagnostics", systemImage: "stethoscope")
                    }
                    
                    Button(action: {
                        queueManager.retryAllFailedJobs()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry All Failed Jobs")
                        }
                    }
                    
                    #if DEBUG
                    Button(action: {
                        SyntheticPipelineRunner.runSyntheticMeetingTest()
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: "flask.fill")
                                .foregroundColor(.purple)
                            Text("Run Synthetic Test Pipeline")
                        }
                    }
                    #endif
                } header: {
                    Text("Advanced")
                }
                
                // MARK: - 5. Privacy & About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Architecture")
                        Spacer()
                        Text("Watch → iPhone → On-Device → Notion")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Cloud Services")
                        Spacer()
                        Text("None (Direct Notion API only)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Cost")
                        Spacer()
                        Text("$0 / month")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                loadCredentials()
                checkSystemCapabilities()
            }
        }
    }
    
    private func loadCredentials() {
        Task {
            if let token = await NotionService.shared.getApiKey() {
                self.apiKey = token
            }
            if let parent = await NotionService.shared.getParentPageId() {
                self.parentPageId = parent
            }
        }
    }
    
    private func checkSystemCapabilities() {
        Task {
            self.isSpeechAvailable = await TranscriptionService.shared.isAvailable()
            self.aiStatus = await MeetingAIService.shared.checkAvailability()
        }
    }
    
    private func saveNotionCredentials() {
        Task {
            await NotionService.shared.setApiKey(apiKey)
            await NotionService.shared.setParentPageId(parentPageId)
            notionStatusMessage = "Credentials saved to Keychain ✓"
            notionStatusColor = .green
        }
    }
    
    private func testNotionConnection() {
        isTestingNotion = true
        notionStatusMessage = "Connecting to Notion..."
        notionStatusColor = .primary
        
        saveNotionCredentials()
        
        Task {
            do {
                let pageId = try await NotionService.shared.verifyAndEnsureTalksPage()
                isTestingNotion = false
                notionStatusMessage = "Connected successfully! 'Talks' page is ready (ID: \(pageId.prefix(8))...)"
                notionStatusColor = .green
            } catch {
                isTestingNotion = false
                notionStatusMessage = error.localizedDescription
                notionStatusColor = .red
            }
        }
    }
}
