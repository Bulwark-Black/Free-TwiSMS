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
                ContactPicker { number in
                    showContacts = false
                    Task { await placeCall(to: number) }
                } onCancel: {
                    showContacts = false
                }
                .ignoresSafeArea()
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

// System contact picker (runs out-of-process — no Contacts permission needed).
struct ContactPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let p = CNContactPickerViewController()
        p.delegate = context.coordinator
        p.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        return p
    }

    func updateUIViewController(_ c: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        // User tapped a specific phone number row.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            if let num = (property.value as? CNPhoneNumber)?.stringValue { onPick(num) }
            else { onCancel() }
        }
        // User tapped a whole contact (single-number contacts).
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            if let num = contact.phoneNumbers.first?.value.stringValue { onPick(num) }
            else { onCancel() }
        }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { onCancel() }
    }
}
