import SwiftUI
import AVFoundation
import UIKit

// MARK: - Calls

struct CallsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: AppRouter
    @State private var calls: [CallRecord] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var callAlert: String?

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
                    List(calls) { c in
                        CallRow(c: c,
                                onCall: { Task { await callBack(c) } },
                                onMessage: { textBack(c) })
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Calls")
            .refreshable { await load() }
            .task { await load(); await poll() }
            .alert("Connecting call", isPresented: Binding(
                get: { callAlert != nil }, set: { if !$0 { callAlert = nil } })) {
                Button("OK", role: .cancel) { callAlert = nil }
            } message: { Text(callAlert ?? "") }
        }
    }

    private func callBack(_ c: CallRecord) async {
        do {
            try await api.call(from: c.via, to: c.from)
            callAlert = "Your phone will ring in a moment — answer it, and you'll be connected to \(c.from_display) showing your \(c.ext_label) number."
        } catch {
            callAlert = "Couldn't start the call: \(error.localizedDescription)"
        }
    }

    private func textBack(_ c: CallRecord) {
        router.open(ThreadTarget(via: c.via, contact: c.from,
                                 title: c.from_display, subtitle: c.ext_label))
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
    let onCall: () -> Void
    let onMessage: () -> Void

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
            Button(action: onMessage) {
                Image(systemName: "message.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            Button(action: onCall) {
                Image(systemName: "phone.arrow.up.right.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button { UIPasteboard.general.string = c.from } label: {
                Label("Copy Number", systemImage: "doc.on.doc")
            }
        }
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
    @EnvironmentObject var router: AppRouter
    @StateObject private var audio = AudioPlayer()
    @State private var vms: [Voicemail] = []
    @State private var loadingID: String?
    @State private var error: String?
    @State private var loaded = false
    @State private var callAlert: String?
    @State private var suggestingID: String?
    @State private var suggestError: String?

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
                                     isSuggesting: suggestingID == vm.id,
                                     onTap: { Task { await toggle(vm) } },
                                     onMessage: { textBack(vm) },
                                     onCall: { Task { await callBack(vm) } },
                                     onSuggest: { Task { await suggestReply(vm) } })
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Voicemail")
            .refreshable { await load() }
            .task { await load(); await poll() }
            .alert("Connecting call", isPresented: Binding(
                get: { callAlert != nil }, set: { if !$0 { callAlert = nil } })) {
                Button("OK", role: .cancel) { callAlert = nil }
            } message: { Text(callAlert ?? "") }
            .alert("Couldn't suggest a reply", isPresented: Binding(
                get: { suggestError != nil }, set: { if !$0 { suggestError = nil } })) {
                Button("OK", role: .cancel) { suggestError = nil }
            } message: { Text(suggestError ?? "") }
        }
    }

    private func textBack(_ vm: Voicemail) {
        router.open(ThreadTarget(via: vm.viaNumber, contact: vm.from,
                                 title: vm.from_display, subtitle: vm.ext_label))
    }

    private func suggestReply(_ vm: Voicemail) async {
        suggestingID = vm.id
        defer { suggestingID = nil }
        do {
            let text = try await api.suggestVoicemailReply(ext: vm.ext, msgid: vm.msgid)
            router.open(ThreadTarget(via: vm.viaNumber, contact: vm.from,
                                     title: vm.from_display, subtitle: vm.ext_label,
                                     prefill: text))
        } catch {
            suggestError = error.localizedDescription
        }
    }

    private func callBack(_ vm: Voicemail) async {
        do {
            try await api.call(from: vm.viaNumber, to: vm.from)
            callAlert = "Your phone will ring in a moment — answer it, and you'll be connected to \(vm.from_display) showing your \(vm.ext_label) number."
        } catch {
            callAlert = "Couldn't start the call: \(error.localizedDescription)"
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
    let isSuggesting: Bool
    let onTap: () -> Void
    let onMessage: () -> Void
    let onCall: () -> Void
    let onSuggest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if vm.isTranscribing {
                Label("Transcribing…", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !vm.transcriptText.isEmpty {
                Text(vm.transcriptText)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 22) {
                Button(action: onMessage) {
                    Label("Text", systemImage: "message.fill").foregroundStyle(Color.accentColor)
                }
                Button(action: onCall) {
                    Label("Call", systemImage: "phone.fill").foregroundStyle(.green)
                }
                if !vm.transcriptText.isEmpty {
                    Button(action: onSuggest) {
                        if isSuggesting {
                            ProgressView()
                        } else {
                            Label("Suggest", systemImage: "sparkles").foregroundStyle(Color.accentColor)
                        }
                    }
                    .disabled(isSuggesting)
                }
                Spacer()
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button { UIPasteboard.general.string = vm.from } label: {
                Label("Copy Number", systemImage: "doc.on.doc")
            }
            if !vm.transcriptText.isEmpty {
                Button { UIPasteboard.general.string = vm.transcriptText } label: {
                    Label("Copy Transcript", systemImage: "doc.on.doc")
                }
            }
        }
    }
}
