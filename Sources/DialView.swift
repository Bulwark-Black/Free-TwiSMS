import SwiftUI
import ContactsUI

struct DialView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var numbers: [OurNumber] = []
    @State private var fromNumber = ""
    @State private var manualNumber = ""
    @State private var showContacts = false
    @State private var callAlert: String?
    @State private var placing = false

    private var api: API { API(settings) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Call from") {
                    if numbers.isEmpty {
                        ProgressView()
                    } else {
                        Picker("Number", selection: $fromNumber) {
                            ForEach(numbers) { n in
                                Text("\(n.label)  ·  \(n.display)").tag(n.number)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                Section("Call a contact") {
                    Button {
                        showContacts = true
                    } label: {
                        Label("Choose from Contacts", systemImage: "person.crop.circle")
                    }
                    .disabled(fromNumber.isEmpty || placing)
                }

                Section("Or type a number") {
                    TextField("(555) 123-4567", text: $manualNumber)
                        .keyboardType(.phonePad)
                    Button {
                        Task { await placeCall(to: manualNumber) }
                    } label: {
                        Label("Call", systemImage: "phone.fill")
                    }
                    .disabled(fromNumber.isEmpty || manualNumber.isEmpty || placing)
                }

                Section {
                    Text("When you call, Twilio rings your phone first — answer it and you'll be connected, showing the number you picked above.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Dial")
            .task { await loadNumbers() }
            .sheet(isPresented: $showContacts) {
                ContactChooser { number in
                    showContacts = false
                    Task { await placeCall(to: number) }
                }
            }
            .alert("Connecting call", isPresented: Binding(
                get: { callAlert != nil }, set: { if !$0 { callAlert = nil } })) {
                Button("OK", role: .cancel) { callAlert = nil }
            } message: { Text(callAlert ?? "") }
        }
    }

    private func loadNumbers() async {
        if let ns = try? await api.numbers() {
            numbers = ns
            if fromNumber.isEmpty { fromNumber = ns.first?.number ?? "" }
        }
    }

    private func placeCall(to raw: String) async {
        let to = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, !fromNumber.isEmpty else { return }
        placing = true; defer { placing = false }
        let label = numbers.first(where: { $0.number == fromNumber })?.label ?? "your number"
        do {
            try await api.call(from: fromNumber, to: to)
            manualNumber = ""
            callAlert = "Your phone will ring in a moment — answer it, and you'll be connected to \(to), showing your \(label) number."
        } catch {
            callAlert = "Couldn't start the call: \(error.localizedDescription)"
        }
    }
}

// The contact picker now lives in Contacts.swift as NamedContactPicker (returns name + number);
// the Dial screen uses ContactChooser (saved contacts + iPhone contacts).
