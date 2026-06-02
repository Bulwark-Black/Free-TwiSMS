import SwiftUI
import AVFoundation

// MARK: - Calls

struct CallsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var calls: [CallRecord] = []
    @State private var error: String?
    @State private var loaded = false

    private var api: API { API(settings) }

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if calls.isEmpty && loaded {
                    ContentUnavailableView("No Calls", systemImage: "phone",
                                           description: Text("Incoming calls will show up here."))
                } else {
                    List(calls) { CallRow(c: $0) }.listStyle(.plain)
                }
            }
            .navigationTitle("Calls")
            .refreshable { await load() }
            .task { await load(); await poll() }
        }
    }

    private func load() async {
        do { calls = try await api.calls(); error = nil }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if let fresh = try? await api.calls() { calls = fresh; error = nil }
        }
    }
}

struct CallRow: View {
    let c: CallRecord

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill((c.missed ? Color.red : Color.green).opacity(0.15))
                Image(systemName: c.missed ? "phone.arrow.down.left.fill" : "phone.fill")
                    .foregroundStyle(c.missed ? .red : .green)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(c.from_display)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(c.missed ? .red : .primary)
                Text(c.ext_label + (c.duration > 0 ? "  ·  \(c.duration)s" : (c.missed ? "  ·  Missed" : "")))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(relativeTime(c.ts)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Voicemail

@MainActor
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingID: String?
    private var player: AVAudioPlayer?

    func play(id: String, data: Data) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.play()
            playingID = id
        } catch {
            print("audio play error:", error.localizedDescription)
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in self.playingID = nil }
    }
}

struct VoicemailView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var audio = AudioPlayer()
    @State private var vms: [Voicemail] = []
    @State private var loadingID: String?
    @State private var error: String?
    @State private var loaded = false

    private var api: API { API(settings) }

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if vms.isEmpty && loaded {
                    ContentUnavailableView("No Voicemail", systemImage: "recordingtape",
                                           description: Text("Voicemails people leave will appear here."))
                } else {
                    List(vms) { vm in
                        VoicemailRow(vm: vm,
                                     isPlaying: audio.playingID == vm.id,
                                     isLoading: loadingID == vm.id,
                                     onTap: { Task { await toggle(vm) } })
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Voicemail")
            .refreshable { await load() }
            .task { await load(); await poll() }
        }
    }

    private func load() async {
        do { vms = try await api.voicemails(); error = nil }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            if let fresh = try? await api.voicemails() { vms = fresh; error = nil }
        }
    }

    private func toggle(_ vm: Voicemail) async {
        if audio.playingID == vm.id { audio.stop(); return }
        loadingID = vm.id
        defer { loadingID = nil }
        if let data = try? await api.voicemailAudio(ext: vm.ext, msgid: vm.msgid) {
            audio.play(id: vm.id, data: data)
        } else {
            error = "Couldn't load that recording"
        }
    }
}

struct VoicemailRow: View {
    let vm: Voicemail
    let isPlaying: Bool
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Button(action: onTap) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15))
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(!vm.has_audio)

            VStack(alignment: .leading, spacing: 3) {
                Text(vm.from_display).font(.body.weight(.semibold))
                Text(vm.ext_label + (vm.duration > 0 ? "  ·  \(vm.duration)s" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(relativeTime(vm.ts)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
