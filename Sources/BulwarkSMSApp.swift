import SwiftUI

@main
struct BulwarkSMSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(AppRouter.shared)
                .preferredColorScheme(.dark)
                .onAppear { PushManager.shared.configure(settings) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if settings.isConfigured {
            ConversationsView()
        } else {
            NavigationStack {
                SettingsView(firstRun: true)
            }
        }
    }
}
