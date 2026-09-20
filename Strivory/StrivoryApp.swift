import SwiftUI

@main
struct StrivoryApp: App {
    @StateObject private var store = AppStore(healthKit: HealthKitService(), cloudBackup: CloudBackupService())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, store.language.locale)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await store.requestHealthAccessAndRefresh()
                        await store.syncICloudBackup(force: false)
                    }
                }
        }
    }
}
