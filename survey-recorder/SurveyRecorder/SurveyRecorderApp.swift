import SwiftUI

@main
struct SurveyRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                NavigationStack { SetupView() }
                    .tabItem { Label("Survey", systemImage: "record.circle") }
                NavigationStack { SessionsView() }
                    .tabItem { Label("Sessions", systemImage: "tray.full") }
            }
        }
    }
}
