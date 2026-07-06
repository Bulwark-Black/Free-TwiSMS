import SwiftUI
import ContactsUI

// Wrapper so a phone number can drive a `.sheet(item:)`.
struct PhoneID: Identifiable { let id: String }

// Chooser used by the Dial screen: saved (Yealink-synced) contacts first, plus a button
// to fall through to the iPhone address book. Returns a phone number.
struct ContactChooser: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void

    @State private var contacts: [Contact] = []
    @State private var query = ""
    @State private var showPhonePicker = false

    private var api: API { API(settings) }
    private var filtered: [Contact] {
        query.isEmpty ? contacts
            : contacts.filter { $0.name.localizedCaseInsensitiveContains(query)
                                || $0.display.contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showPhonePicker = true } label: {
                        Label("From iPhone Contacts", systemImage: "person.crop.circle")
                    }
                }
                Section("Saved contacts") {
                    if contacts.isEmpty {
                        Text("No saved contacts yet").foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { c in
                        Button { dismiss(); onPick(c.phone) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.name).foregroundStyle(.primary)
                                Text(c.display).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query)
            .navigationTitle("Choose Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .task { contacts = (try? await api.contacts()) ?? [] }
            .sheet(isPresented: $showPhonePicker) {
                NamedContactPicker { _, phone in
                    showPhonePicker = false
                    if !phone.isEmpty { dismiss(); onPick(phone) }
                }
            }
        }
    }
}

// System contact picker that returns the name too (DialView's ContactPicker returns only the number).
// Runs out-of-process, so it needs no Contacts permission.
struct NamedContactPicker: UIViewControllerRepresentable {
    var onPick: (_ name: String, _ phone: String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.displayedPropertyKeys = [CNContactPhoneNumbersKey]   // show numbers to pick
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (String, String) -> Void
        init(onPick: @escaping (String, String) -> Void) { self.onPick = onPick }

        private func fullName(_ c: CNContact) -> String {
            CNContactFormatter.string(from: c, style: .fullName) ?? ""
        }

        // User drilled in and tapped a specific phone number.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            let phone = (property.value as? CNPhoneNumber)?.stringValue ?? ""
            onPick(fullName(property.contact), phone)
        }

        // User tapped a contact (single number) directly.
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(fullName(contact), contact.phoneNumbers.first?.value.stringValue ?? "")
        }
    }
}

// Sheet to name a number (or add a new contact). Saving syncs to the desk phone.
struct NameContactSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    let existingPhone: String?           // nil => adding a new contact (phone is editable)
    var onSaved: () -> Void = {}

    @State private var phone = ""
    @State private var name = ""
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?

    private var api: API { API(settings) }
    private var isNew: Bool { existingPhone == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Number") {
                    if isNew {
                        TextField("+1…", text: $phone).keyboardType(.phonePad)
                    } else {
                        Text(existingPhone ?? "").foregroundStyle(.secondary)
                    }
                }
                Section("Name") {
                    TextField("Contact name", text: $name)
                        .textInputAutocapitalization(.words)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                if !isNew && !name.isEmpty {
                    Section {
                        Button("Remove Contact", role: .destructive) { Task { await save(remove: true) } }
                    }
                }
            }
            .navigationTitle(isNew ? "New Contact" : "Name Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save(remove: false) } }
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || (isNew && phone.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .task {
                guard !loaded else { return }
                loaded = true
                // Prefill the current name when renaming an existing number (match last 10 digits).
                guard let p = existingPhone else { return }
                let want = String(p.filter { $0.isNumber }.suffix(10))
                if let list = try? await api.contacts(),
                   let hit = list.first(where: { String($0.phone.filter { $0.isNumber }.suffix(10)) == want }) {
                    name = hit.name
                }
            }
        }
    }

    private func save(remove: Bool) async {
        saving = true; error = nil
        defer { saving = false }
        let target = existingPhone ?? phone
        do {
            try await api.saveContact(phone: target, name: remove ? "" : name)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// Contacts tab: browse, add, edit, delete, call/text. Everything here syncs to the Yealink.
struct ContactsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var router: AppRouter
    @State private var contacts: [Contact] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var showAdd = false
    @State private var showPicker = false
    @State private var editing: Contact?
    @State private var acting: Contact?
    @State private var callAlert: String?

    private var api: API { API(settings) }

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("Couldn't load", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if contacts.isEmpty && loaded {
                    ContentUnavailableView("No Contacts", systemImage: "person.crop.circle",
                                           description: Text("Add a contact, or save one from a call, text, or voicemail. Contacts sync to your desk phone."))
                } else {
                    List {
                        ForEach(contacts) { c in
                            Button { acting = c } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                        Text(c.display).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "phone.fill").foregroundStyle(.green)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { try? await api.saveContact(phone: c.phone, name: ""); await load() }
                                } label: { Label("Delete", systemImage: "trash") }
                                Button { editing = c } label: { Label("Edit", systemImage: "pencil") }.tint(.blue)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showPicker = true } label: {
                            Label("From iPhone Contacts", systemImage: "person.crop.circle")
                        }
                        Button { showAdd = true } label: {
                            Label("Enter Manually", systemImage: "square.and.pencil")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                NameContactSheet(existingPhone: nil) { Task { await load() } }
            }
            .sheet(isPresented: $showPicker) {
                NamedContactPicker { name, phone in
                    showPicker = false
                    guard !phone.isEmpty else { return }
                    Task { try? await api.saveContact(phone: phone, name: name); await load() }
                }
            }
            .sheet(item: $editing) { c in
                NameContactSheet(existingPhone: c.phone) { Task { await load() } }
            }
            .sheet(item: $acting) { c in
                ContactActionSheet(contact: c,
                    onCall: { n in Task { await placeCall(from: n, to: c) } },
                    onText: { n in router.open(ThreadTarget(via: n.number, contact: c.phone,
                                                            title: c.name, subtitle: n.label)) })
            }
            .alert("Connecting call", isPresented: Binding(
                get: { callAlert != nil }, set: { if !$0 { callAlert = nil } })) {
                Button("OK", role: .cancel) { callAlert = nil }
            } message: { Text(callAlert ?? "") }
        }
    }

    private func load() async {
        do { contacts = try await api.contacts(); error = nil }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func placeCall(from n: OurNumber, to c: Contact) async {
        do {
            try await api.call(from: n.number, to: c.phone)
            callAlert = "Your phone will ring in a moment — answer it, and you'll be connected to \(c.name), showing your \(n.label) number."
        } catch {
            callAlert = "Couldn't start the call: \(error.localizedDescription)"
        }
    }
}

// Pick which business line to call/text a saved contact from.
struct ContactActionSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let contact: Contact
    var onCall: (OurNumber) -> Void
    var onText: (OurNumber) -> Void

    @State private var numbers: [OurNumber] = []
    @State private var from = ""

    private var api: API { API(settings) }
    private var selected: OurNumber? { numbers.first(where: { $0.number == from }) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(contact.name).font(.headline)
                    Text(contact.display).foregroundStyle(.secondary)
                }
                Section("Use my number") {
                    if numbers.isEmpty {
                        ProgressView()
                    } else {
                        Picker("Number", selection: $from) {
                            ForEach(numbers) { n in Text("\(n.label)  ·  \(n.display)").tag(n.number) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                }
                Section {
                    Button {
                        if let n = selected { dismiss(); onCall(n) }
                    } label: { Label("Call", systemImage: "phone.fill") }
                        .disabled(selected == nil)
                    Button {
                        if let n = selected { dismiss(); onText(n) }
                    } label: { Label("Text", systemImage: "message.fill") }
                        .disabled(selected == nil)
                }
            }
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .task {
                if numbers.isEmpty, let ns = try? await api.numbers() {
                    numbers = ns
                    if from.isEmpty { from = ns.first?.number ?? "" }
                }
            }
        }
    }
}
