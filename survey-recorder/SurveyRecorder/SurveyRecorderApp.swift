import SwiftUI

@main
struct SurveyRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { SetupView() }
                    .tabItem { Label("Survey", systemImage: "record.circle") }
                NavigationStack { LivePositioningView() }
                    .tabItem { Label("Live", systemImage: "location.north.circle") }
                NavigationStack { MapHeatmapView() }
                    .tabItem { Label("Map", systemImage: "map") }
                NavigationStack { SessionsView() }
                    .tabItem { Label("Sessions", systemImage: "tray.full") }
            }
        }
    }
}
