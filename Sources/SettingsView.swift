import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let firstRun: Bool

    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("https://pbx.bulwarkblack.com", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            Section("Login") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
            }
            if !firstRun {
                Section("Messaging") {
                    NavigationLink {
                        TemplatesEditor()
                    } label: {
                        Label("Quick Replies", systemImage: "bolt")
                    }
                }
            }
            if let result {
                Section {
                    Label(result, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(ok ? .green : .red)
                }
            }
            Section {
                Button {
                    Task { await testAndSave() }
                } label: {
                    HStack {
                        Text(firstRun ? "Connect" : "Test & Save")
                        if testing { Spacer(); ProgressView() }
                    }
                }
                .disabled(testing || baseURL.isEmpty || username.isEmpty || password.isEmpty)
            }
        }
        .navigationTitle(firstRun ? "Welcome" : "Settings")
        .toolbar {
            if !firstRun {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            baseURL = settings.baseURL
            username = settings.username
            password = settings.password
        }
    }

    private func testAndSave() async {
        testing = true; result = nil
        settings.baseURL = baseURL
        settings.username = username
        settings.password = password
        do {
            _ = try await API(settings).numbers()
            settings.save()
            ok = true; result = "Connected"
            try? await Task.sleep(for: .milliseconds(400))
            if !firstRun { dismiss() }
        } catch {
            ok = false; result = error.localizedDescription
        }
        testing = false
    }
}

struct NewMessageView: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let numbers: [OurNumber]
    let defaultFrom: String

    @State private var from = ""
    @State private var to = ""
    @State private var body_ = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("From") {
                    Picker("Number", selection: $from) {
                        ForEach(numbers) { n in
                            Text("\(n.label) (\(n.display))").tag(n.number)
                        }
                    }
                }
                Section("To") {
                    TextField("+1...", text: $to)
                        .keyboardType(.phonePad)
                }
                Section("Message") {
                    TextField("Type a message", text: $body_, axis: .vertical)
                        .lineLimit(3...6)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { Task { await send() } }
                        .disabled(sending || to.isEmpty || body_.isEmpty)
                }
            }
            .onAppear { from = defaultFrom.isEmpty ? (numbers.first?.number ?? "") : defaultFrom }
        }
    }

    private func send() async {
        sending = true; error = nil
        do {
            try await API(settings).send(from: from, to: to, body: body_)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        sending = false
    }
}
