import SwiftUI
import UIKit
import UserNotifications

// Destination used by both the conversation list and notification taps.
struct ThreadTarget: Hashable {
    let via: String
    let contact: String
    let title: String
    let subtitle: String
    var prefill: String? = nil   // seed the reply box (e.g. an AI-suggested reply)
}

@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var path: [ThreadTarget] = []
    @Published var selectedTab = 0     // 0 = Messages, 1 = Calls, 2 = Voicemail
    func open(_ t: ThreadTarget) { selectedTab = 0; path = [t] }
    func openCalls() { selectedTab = 1 }
}

@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()
    private var settings: AppSettings?
    private var pendingToken: String?

    func configure(_ s: AppSettings) {
        settings = s
        Task { await sendToken() }
    }

    func requestAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func didRegister(_ deviceToken: Data) {
        pendingToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await sendToken() }
    }

    private func sendToken() async {
        guard let settings, settings.isConfigured, let token = pendingToken,
              let url = URL(string: settings.baseURL + "/api/register-device") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(settings.authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        _ = try? await URLSession.shared.data(for: req)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Push registration failed:", error.localizedDescription)
    }

    // Show banners even when the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    // Open the right conversation when a notification is tapped.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let u = response.notification.request.content.userInfo
        if (u["type"] as? String) == "call" {
            await MainActor.run { AppRouter.shared.openCalls() }
        } else if let via = u["via"] as? String, let contact = u["contact"] as? String {
            let target = ThreadTarget(via: via, contact: contact,
                                      title: (u["contact_display"] as? String) ?? contact,
                                      subtitle: (u["via_label"] as? String) ?? "")
            await MainActor.run { AppRouter.shared.open(target) }
        }
    }
}
