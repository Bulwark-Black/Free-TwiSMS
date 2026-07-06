import SwiftUI

// Wrapper so a phone number can drive a `.sheet(item:)`.
struct PhoneID: Identifiable { let id: String }

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

// Contacts tab: browse, add, edit, delete. Everything here syncs to the Yealink.
struct ContactsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var contacts: [Contact] = []
    @State private var error: String?
    @State private var loaded = false
    @State private var showAdd = false
    @State private var editing: Contact?

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
                            Button { editing = c } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(c.display).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in Task { await remove(offsets) } }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showAdd) {
                NameContactSheet(existingPhone: nil) { Task { await load() } }
            }
            .sheet(item: $editing) { c in
                NameContactSheet(existingPhone: c.phone) { Task { await load() } }
            }
        }
    }

    private func load() async {
        do { contacts = try await api.contacts(); error = nil }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func remove(_ offsets: IndexSet) async {
        for i in offsets {
            try? await api.saveContact(phone: contacts[i].phone, name: "")
        }
        await load()
    }
}
