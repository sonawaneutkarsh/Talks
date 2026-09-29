import SwiftUI

@main
struct TalksWatchApp: App {
    @StateObject private var connectivityManager = WatchConnectivityManager.shared
    @StateObject private var recordingManager = WatchRecordingManager.shared
    
    init() {
        _ = WatchConnectivityManager.shared
        _ = WatchRecordingManager.shared
    }
    
    var body: some Scene {
        WindowGroup {
            WatchContentView()
        }
    }
}
