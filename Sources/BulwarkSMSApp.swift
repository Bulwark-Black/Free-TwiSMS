import SwiftUI

@main
struct BulwarkSMSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var templates = TemplateStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(templates)
                .environmentObject(AppRouter.shared)
                .preferredColorScheme(.dark)
                .onAppear { PushManager.shared.configure(settings) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: AppRouter

    var body: some View {
        if settings.isConfigured {
            TabView(selection: $router.selectedTab) {
                ConversationsView()
                    .tabItem { Label("Messages", systemImage: "message.fill") }
                    .tag(0)
                CallsView()
                    .tabItem { Label("Calls", systemImage: "phone.fill") }
                    .tag(1)
                VoicemailView()
                    .tabItem { Label("Voicemail", systemImage: "recordingtape") }
                    .tag(2)
                DialView()
                    .tabItem { Label("Dial", systemImage: "phone.arrow.up.right.fill") }
                    .tag(3)
            }
        } else {
            NavigationStack {
                SettingsView(firstRun: true)
            }
        }
    }
}
