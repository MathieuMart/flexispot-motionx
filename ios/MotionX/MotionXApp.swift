import SwiftUI

@main
struct MotionXApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.wentToBackground()
            default: break
            }
        }
        .backgroundTask(.appRefresh(AppModel.refreshTaskId)) {
            await AppModel.shared.backgroundRefresh()
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Direct", systemImage: "figure.walk") }
            HistoryView()
                .tabItem { Label("Historique", systemImage: "calendar") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
        }
    }
}
