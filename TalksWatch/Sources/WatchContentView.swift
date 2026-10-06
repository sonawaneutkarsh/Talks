import SwiftUI

public struct WatchContentView: View {
    @ObservedObject var recordingManager = WatchRecordingManager.shared
    @ObservedObject var connectivityManager = WatchConnectivityManager.shared
    @State private var isScreenOff = false
    #if DEBUG
    @State private var showDiagnostics = false
    #endif
    
    public init() {}
    
    public var body: some View {
        ZStack {
            if recordingManager.isRecording && isScreenOff {
                // MARK: - Screen Off Distraction-Free Mode
                // Complete blackout for academic/research meetings
                Color.black
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        // Barely perceptible dim dot to confirm active capture without lighting the room
                        Circle()
                            .fill(Color.red.opacity(0.15))
                            .frame(width: 4, height: 4)
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // Safe wake-on-tap: returns to controls WITHOUT stopping recording
                        isScreenOff = false
                    }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if recordingManager.isRecording {
                            // MARK: - Recording Active State
                            VStack(spacing: 6) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 8, height: 8)
                                        .opacity(recordingManager.audioLevel > 0.08 ? 1.0 : 0.45)
                                        .animation(.easeInOut(duration: 0.25), value: recordingManager.audioLevel)
                                    Text("Recording")
                                        .font(.system(.subheadline, design: .rounded))
                                        .fontWeight(.semibold)
                                        .foregroundColor(.red)
                                }
                                
                                Text(recordingManager.formattedElapsedTime)
                                    .font(.system(size: 32, weight: .bold, design: .rounded))
                                    .minimumScaleFactor(0.75)
                                    .lineLimit(1)
                                
                                Button(action: {
                                    recordingManager.stopRecording()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "stop.fill")
                                        Text("Stop")
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.red)
                                    .cornerRadius(22)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                                
                                Button(action: {
                                    isScreenOff = true
                                }) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "display.slash")
                                        Text("Screen Off")
                                    }
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(18)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            // MARK: - Idle State
                            VStack(spacing: 8) {
                                Text("Talks")
                                    .font(.system(.headline, design: .rounded))
                                    .fontWeight(.bold)
                                
                                Button(action: {
                                    recordingManager.startRecording()
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "mic.fill")
                                            .font(.title3)
                                        Text("Record")
                                            .font(.system(.headline, design: .rounded))
                                            .fontWeight(.bold)
                                    }
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.red)
                                    .cornerRadius(24)
                                }
                                .buttonStyle(.plain)
                                
                                // Status Message: Ready / Saving... / Transferring... / Sent ✓
                                if let status = recordingManager.statusMessage {
                                    HStack(spacing: 4) {
                                        if status == "Sent ✓" {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.green)
                                        }
                                        Text(status)
                                            .font(.footnote)
                                            .fontWeight(.semibold)
                                            .foregroundColor(status == "Sent ✓" ? .green : .secondary)
                                    }
                                    .padding(.vertical, 2)
                                } else {
                                    Text("Ready")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                        .padding(.vertical, 2)
                                }
                                
                                if let error = recordingManager.errorMessage {
                                    Text(error)
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                        .multilineTextAlignment(.center)
                                }
                                
                                #if DEBUG
                                // Collapsed Diagnostics (Debug Only, No Ping)
                                Button(action: {
                                    showDiagnostics.toggle()
                                }) {
                                    HStack {
                                        Text("Diagnostics")
                                        Spacer()
                                        Image(systemName: showDiagnostics ? "chevron.up" : "chevron.down")
                                    }
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 6)
                                
                                if showDiagnostics {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Session: \(connectivityManager.diagnostics.activationState)")
                                        Text("Companion: \(connectivityManager.diagnostics.isCompanionAppInstalled ? "YES" : "NO")")
                                        Text("Phone: \(connectivityManager.diagnostics.isReachable ? "Reachable" : "Unreachable")")
                                        Text("Queue: \(connectivityManager.diagnostics.outstandingTransfersCount)")
                                        if let ack = connectivityManager.diagnostics.lastAckReceived {
                                            Text("ACK: \(ack)").foregroundColor(.green)
                                        }
                                        if let err = connectivityManager.diagnostics.lastError {
                                            Text("Err: \(err)").foregroundColor(.red)
                                        }
                                        
                                        Button(action: {
                                            connectivityManager.retryPendingTransfers(force: true)
                                        }) {
                                            Text("Retry Transfer")
                                                .font(.system(size: 10))
                                        }
                                        .buttonStyle(.bordered)
                                        .padding(.top, 2)
                                    }
                                    .font(.system(size: 8, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(4)
                                    .background(Color.gray.opacity(0.15))
                                    .cornerRadius(6)
                                }
                                #endif
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}
