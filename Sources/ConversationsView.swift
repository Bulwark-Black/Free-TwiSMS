import SwiftUI
import UserNotifications

struct ConversationsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var conversations: [Conversation] = []
    @State private var numbers: [OurNumber] = []
    @State private var box = "all"
    @State private var error: String?
    @State private var loaded = false
    @State private var showSettings = false
    @State private var showCompose = false

    private var api: API { API(settings) }

    private var filtered: [Conversation] {
        box == "all" ? conversations : conversations.filter { $0.via == box }
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if let error {
                    ContentUnavailableView {
                        Label("Couldn't load", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if filtered.isEmpty && loaded {
                    ContentUnavailableView("No Messages", systemImage: "tray",
                                           description: Text("Texts you receive will show up here."))
                } else {
                    List {
                        ForEach(filtered) { c in
                            NavigationLink(value: ThreadTarget(via: c.via, contact: c.contact,
                                                               title: c.displayName, subtitle: c.via_label)) {
                                ConversationRow(c: c)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { switcher }
            .navigationDestination(for: ThreadTarget.self) { t in
                ThreadView(via: t.via, contact: t.contact,
                           title: t.title, subtitle: t.subtitle, prefill: t.prefill)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                }
            }
            .refreshable { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task {
                        try? await UNUserNotificationCenter.current().setBadgeCount(0)
                        await api.markRead()
                        await load()
                    }
                }
            }
            .task {
                PushManager.shared.configure(settings)
                PushManager.shared.requestAndRegister()
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
                await api.markRead()
                await loadNumbers()
                await load()
                await poll()
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView(firstRun: false) }
            }
            .sheet(isPresented: $showCompose) {
                NewMessageView(numbers: numbers, defaultFrom: box == "all" ? (numbers.first?.number ?? "") : box)
            }
        }
    }

    private var switcher: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                pill("All", value: "all")
                ForEach(numbers) { n in pill(n.label, value: n.number) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func pill(_ title: String, value: String) -> some View {
        Button { box = value } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(box == value ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(box == value ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func loadNumbers() async {
        numbers = (try? await api.numbers()) ?? numbers
    }

    private func load() async {
        do {
            conversations = try await api.conversations()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    // Light background polling so new texts appear without manual refresh.
    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(12))
            if let fresh = try? await api.conversations() { conversations = fresh; error = nil }
        }
    }
}

struct ConversationRow: View {
    let c: Conversation

    private var initials: String {
        if let n = c.contact_name, !n.isEmpty {
            let letters = n.split(separator: " ").compactMap(\.first)
            if !letters.isEmpty { return String(letters.prefix(2)).uppercased() }
        }
        return String(c.contact.filter(\.isNumber).suffix(2))
    }

    private var draft: String {
        DraftStore.get(via: c.via, contact: c.contact)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(.tertiarySystemFill))
                Text(initials).font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(c.displayName).font(.body.weight(.semibold))
                    Spacer()
                    Text(relativeTime(c.last_ts)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(c.via_label)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    if draft.isEmpty {
                        Text((c.last_dir == "out" ? "You: " : "") + c.last_body)
                            .font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        (Text("Draft: ").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                            + Text(draft).font(.subheadline).foregroundStyle(.secondary))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
