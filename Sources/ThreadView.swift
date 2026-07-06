import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ThreadView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var templates: TemplateStore
    let via: String
    let contact: String
    let title: String
    let subtitle: String
    var prefill: String? = nil

    @State private var messages: [Message] = []
    @State private var draft = ""
    @State private var draftLoaded = false
    @State private var error: String?
    @State private var sending = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var showEmoji = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var callAlert: String?
    @State private var suggesting = false
    @State private var showName = false

    private var api: API { API(settings) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { m in
                            Bubble(message: m).id(m.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                }
                .onChange(of: messages) { _, _ in scrollToEnd(proxy) }
                .onAppear { scrollToEnd(proxy, animated: false) }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.bottom, 4)
            }

            replyBar
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await suggestReply() } } label: {
                    if suggesting {
                        ProgressView()
                    } else {
                        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    }
                }
                .disabled(suggesting)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showName = true } label: {
                    Image(systemName: "person.crop.circle").foregroundStyle(Color.accentColor)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await callContact() } } label: {
                    Image(systemName: "phone.fill").foregroundStyle(.green)
                }
            }
        }
        .sheet(isPresented: $showName) {
            NameContactSheet(existingPhone: contact)
        }
        .alert("Connecting call", isPresented: Binding(
            get: { callAlert != nil }, set: { if !$0 { callAlert = nil } })) {
            Button("OK", role: .cancel) { callAlert = nil }
        } message: { Text(callAlert ?? "") }
        .task { await load(); await poll() }
        .onAppear {
            if !draftLoaded {
                let saved = DraftStore.get(via: via, contact: contact)
                // A prefill (e.g. an AI-suggested reply) wins over an empty saved draft.
                draft = (prefill?.isEmpty == false) ? prefill! : saved
                draftLoaded = true
            }
        }
        .onChange(of: draft) { _, new in
            if draftLoaded { DraftStore.set(new, via: via, contact: contact) }
        }
    }

    private func insertTemplate(_ t: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = t
        } else {
            draft += (draft.hasSuffix(" ") ? "" : " ") + t
        }
    }

    private func suggestReply() async {
        suggesting = true; error = nil
        defer { suggesting = false }
        do {
            draft = try await api.suggestThreadReply(via: via, contact: contact)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func callContact() async {
        do {
            try await api.call(from: via, to: contact)
            callAlert = "Your phone will ring in a moment — answer it, and you'll be connected to \(title) showing your \(subtitle) number."
        } catch {
            callAlert = "Couldn't start the call: \(error.localizedDescription)"
        }
    }

    private var replyBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photo", systemImage: "photo") }
                Button { showFileImporter = true } label: { Label("File", systemImage: "doc") }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }
            .disabled(sending)

            Button { showEmoji = true } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.accentColor)
            }

            Menu {
                if templates.templates.isEmpty {
                    Text("No quick replies yet — add some in Settings")
                } else {
                    ForEach(templates.templates, id: \.self) { t in
                        Button(t) { insertTemplate(t) }
                    }
                }
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
            }
            .disabled(sending)

            TextField("Text Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .lineLimit(1...4)

            Button {
                Task { await send() }
            } label: {
                Image(systemName: sending ? "circle.dotted" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .disabled(!canSend || sending)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
        .sheet(isPresented: $showEmoji) {
            EmojiPicker { draft += $0 }
                .presentationDetents([.height(280)])
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { Task { await sendFile(url) } }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await sendImage(item) }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() async {
        do { messages = try await api.thread(via: via, contact: contact); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func poll() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(8))
            if let fresh = try? await api.thread(via: via, contact: contact) { messages = fresh }
        }
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sending = true; error = nil
        do {
            try await api.send(from: via, to: contact, body: text)
            draft = ""
            await load()
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }

    private func sendImage(_ item: PhotosPickerItem) async {
        sending = true; error = nil
        defer { sending = false; pickerItem = nil }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self),
                  let img = UIImage(data: raw) else {
                error = "Couldn't read that image"; return
            }
            // Downscale + compress so MMS stays within carrier size limits.
            let jpeg = resizedJPEG(img, maxDimension: 1280, quality: 0.7)
            try await api.sendMMS(from: via, to: contact,
                                  body: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                  imageData: jpeg, contentType: "image/jpeg")
            draft = ""
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendFile(_ url: URL) async {
        sending = true; error = nil
        defer { sending = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let fileData = try Data(contentsOf: url)
            guard fileData.count <= 12_000_000 else {
                error = "File is too large (max 12 MB)"; return
            }
            try await api.sendFile(from: via, to: contact,
                                   body: draft.trimmingCharacters(in: .whitespacesAndNewlines),
                                   fileData: fileData, filename: url.lastPathComponent)
            draft = ""
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func resizedJPEG(_ image: UIImage, maxDimension: CGFloat, quality: CGFloat) -> Data {
        let size = image.size
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return scaled.jpegData(compressionQuality: quality) ?? Data()
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = messages.last else { return }
        if animated { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
        else { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

struct EmojiPicker: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private let emojis = ["😀","😂","🥹","😊","😍","😘","😎","🤔","😅","🙃","😉","😇",
                          "👍","👎","🙏","👏","🙌","💪","🤝","👋","🤙","✌️","🤞","🫶",
                          "❤️","🔥","✨","🎉","💯","✅","❌","⚠️","📞","📱","💬","📍",
                          "😢","😭","😡","🤯","🥳","😴","🤷","🤦","💀","👀","🚀","💰"]
    private let cols = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Emoji").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            ScrollView {
                LazyVGrid(columns: cols, spacing: 14) {
                    ForEach(emojis, id: \.self) { e in
                        Button { onPick(e) } label: {
                            Text(e).font(.system(size: 30))
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// Turn raw URLs in a message into tappable, underlined links (white, to read on colored bubbles).
func linkified(_ text: String) -> AttributedString {
    var attr = AttributedString(text)
    guard let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue) else { return attr }
    let ns = text as NSString
    for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        guard let url = match.url,
              let sr = Range(match.range, in: text),
              let lo = AttributedString.Index(sr.lowerBound, within: attr),
              let hi = AttributedString.Index(sr.upperBound, within: attr) else { continue }
        attr[lo..<hi].link = url
        attr[lo..<hi].underlineStyle = .single
        attr[lo..<hi].foregroundColor = .white
    }
    return attr
}

struct Bubble: View {
    @EnvironmentObject var settings: AppSettings
    let message: Message

    var body: some View {
        HStack {
            if !message.incoming { Spacer(minLength: 50) }
            VStack(alignment: message.incoming ? .leading : .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.media, id: \.url) { m in
                        if m.isImage {
                            AuthImage(path: m.url).environmentObject(settings)
                        } else {
                            Label("Attachment", systemImage: "paperclip")
                                .font(.subheadline)
                        }
                    }
                    if !message.body.isEmpty {
                        Text(linkified(message.body))
                            .font(.body)
                            .textSelection(.enabled)
                            .tint(.white)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(message.incoming ? Color.green : Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(BubbleShape(incoming: message.incoming))

                HStack(spacing: 4) {
                    if !message.deliveryStatus.isEmpty {
                        Text(message.deliveryStatus)
                            .foregroundStyle(message.deliveryFailed ? Color.red : Color.secondary)
                        Text("·").foregroundStyle(.secondary)
                    }
                    Text(clockTime(message.ts)).foregroundStyle(.secondary)
                }
                .font(.caption2)
            }
            if message.incoming { Spacer(minLength: 50) }
        }
    }
}

struct BubbleShape: Shape {
    let incoming: Bool
    func path(in rect: CGRect) -> Path {
        let corners: UIRectCorner = incoming
            ? [.topLeft, .topRight, .bottomRight]
            : [.topLeft, .topRight, .bottomLeft]
        let p = UIBezierPath(roundedRect: rect, byRoundingCorners: corners,
                             cornerRadii: CGSize(width: 18, height: 18))
        return Path(p.cgPath)
    }
}

// Loads an authenticated image from the connector and displays it.
struct AuthImage: View {
    @EnvironmentObject var settings: AppSettings
    let path: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.2))
                    .frame(width: 200, height: 140)
                    .overlay(ProgressView())
            }
        }
        .task {
            if let data = try? await API(settings).mediaData(path) {
                image = UIImage(data: data)
            }
        }
    }
}
