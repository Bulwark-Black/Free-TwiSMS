import SwiftUI

// MARK: - Saved drafts (per conversation, stored locally)

enum DraftStore {
    private static func key(via: String, contact: String) -> String { "draft.\(via)|\(contact)" }

    static func get(via: String, contact: String) -> String {
        UserDefaults.standard.string(forKey: key(via: via, contact: contact)) ?? ""
    }

    static func set(_ text: String, via: String, contact: String) {
        let k = key(via: via, contact: contact)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: k)
        } else {
            UserDefaults.standard.set(text, forKey: k)
        }
    }
}

// MARK: - Quick-reply templates (shared, editable in Settings)

@MainActor
final class TemplateStore: ObservableObject {
    @Published var templates: [String] { didSet { save() } }
    private static let key = "quickReplyTemplates"

    init() {
        templates = UserDefaults.standard.stringArray(forKey: Self.key) ?? [
            "I'll call you right back.",
            "Thanks, got it!",
            "We're open 8-5, Monday through Friday.",
            "What's the best address to reach you?",
            "On my way.",
        ]
    }

    private func save() { UserDefaults.standard.set(templates, forKey: Self.key) }

    func add(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        templates.append(t)
    }

    func remove(at offsets: IndexSet) { templates.remove(atOffsets: offsets) }
    func move(from: IndexSet, to: Int) { templates.move(fromOffsets: from, toOffset: to) }
}

struct TemplatesEditor: View {
    @EnvironmentObject var templates: TemplateStore
    @State private var newTemplate = ""

    var body: some View {
        List {
            Section("Add a quick reply") {
                HStack(alignment: .top) {
                    TextField("New quick reply", text: $newTemplate, axis: .vertical)
                        .lineLimit(1...4)
                    Button("Add") {
                        templates.add(newTemplate)
                        newTemplate = ""
                    }
                    .disabled(newTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Your quick replies") {
                if templates.templates.isEmpty {
                    Text("No templates yet").foregroundStyle(.secondary)
                } else {
                    ForEach(templates.templates, id: \.self) { t in Text(t) }
                        .onDelete { templates.remove(at: $0) }
                        .onMove { templates.move(from: $0, to: $1) }
                }
            }
        }
        .navigationTitle("Quick Replies")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}
