import SwiftUI

@main
struct TalksApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        PipelineLogger.log(stage: "[LAUNCH] TalksApp.init ENTER")
        _ = PhoneConnectivityManager.shared
        _ = JobQueueManager.shared
        PipelineLogger.log(stage: "[LAUNCH] TalksApp.init EXIT")
    }
    
    var body: some Scene {
        let _ = PipelineLogger.log(stage: "[LAUNCH] WindowGroup construction")
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                PipelineLogger.log(stage: "[LIFECYCLE] scene -> active")
            case .inactive:
                PipelineLogger.log(stage: "[LIFECYCLE] scene -> inactive")
            case .background:
                PipelineLogger.log(stage: "[LIFECYCLE] scene -> background")
            @unknown default:
                break
            }
        }
    }
}
