import Foundation
import Security
import SwiftUI

// MARK: - Models

struct OurNumber: Codable, Identifiable, Hashable {
    let number: String
    let label: String
    let display: String
    var id: String { number }
}

struct Conversation: Codable, Identifiable, Hashable {
    let via: String
    let via_label: String
    let contact: String
    let contact_display: String
    let contact_name: String?
    let last_body: String
    let last_ts: Double
    let last_dir: String
    var id: String { via + "|" + contact }
    var displayName: String { (contact_name?.isEmpty == false) ? contact_name! : contact_display }
}

struct Media: Codable, Hashable {
    let url: String
    let type: String
    var isImage: Bool { type.hasPrefix("image/") }
}

struct Message: Codable, Identifiable, Hashable {
    let ts: Double
    let body: String
    let dir: String
    let media: [Media]
    let status: String?
    let failed: Bool?
    let mid: Int?
    enum CodingKeys: String, CodingKey {
        case ts, body, dir, media, status, failed, mid = "id"
    }
    var id: String { "\(ts)-\(dir)-\(body.hashValue)-\(media.count)" }
    var incoming: Bool { dir == "in" }
    var deliveryStatus: String { incoming ? "" : (status ?? "") }
    var deliveryFailed: Bool { !incoming && (failed ?? false) }
}

struct CallRecord: Codable, Identifiable {
    let ts: Double
    let from: String
    let from_display: String
    let contact_name: String?
    let ext: String
    let via: String
    let ext_label: String
    let disposition: String
    let missed: Bool
    let duration: Int
    let uniqueid: String?
    var id: String { "\(ts)-\(from)-\(ext)" }
    var displayName: String { (contact_name?.isEmpty == false) ? contact_name! : from_display }
}

struct Voicemail: Codable, Identifiable {
    let ext: String
    let ext_label: String
    let msgid: String
    let via: String?
    let from: String
    let from_display: String
    let callerid: String
    let ts: Double
    let duration: Int
    let has_audio: Bool
    let transcript: String?
    let transcript_status: String?
    let contact_name: String?
    enum CodingKeys: String, CodingKey {
        case ext, ext_label, msgid = "id", via, from, from_display, callerid, ts, duration,
             has_audio, transcript, transcript_status, contact_name
    }
    var id: String { ext + "-" + msgid }
    var viaNumber: String { via ?? "" }
    var displayName: String { (contact_name?.isEmpty == false) ? contact_name! : from_display }
    var transcriptText: String { (transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var isTranscribing: Bool { transcriptText.isEmpty && (transcript_status ?? "pending") != "done" }
}

struct Contact: Codable, Identifiable, Hashable {
    let phone: String
    let name: String
    let display: String
    var id: String { phone }
}

// MARK: - Helpers

func encodeQuery(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func relativeTime(_ ts: Double) -> String {
    let date = Date(timeIntervalSince1970: ts)
    let cal = Calendar.current
    let f = DateFormatter()
    if cal.isDateInToday(date) { f.dateFormat = "h:mm a" }
    else if cal.isDate(date, equalTo: Date(), toGranularity: .year) { f.dateFormat = "MMM d" }
    else { f.dateFormat = "M/d/yy" }
    return f.string(from: date)
}

func clockTime(_ ts: Double) -> String {
    let f = DateFormatter()
    f.dateFormat = "MMM d, h:mm a"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

// MARK: - Keychain

enum Keychain {
    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrAccount as String: key,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    @Published var baseURL: String
    @Published var username: String
    @Published var password: String

    init() {
        let d = UserDefaults.standard
        baseURL = d.string(forKey: "baseURL") ?? "https://pbx.bulwarkblack.com"
        username = d.string(forKey: "username") ?? "albert"
        password = Keychain.get("inbox_password") ?? ""
    }

    var isConfigured: Bool { !baseURL.isEmpty && !username.isEmpty && !password.isEmpty }

    var authHeader: String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    func save() {
        let d = UserDefaults.standard
        d.set(baseURL.trimmingCharacters(in: .whitespaces), forKey: "baseURL")
        d.set(username.trimmingCharacters(in: .whitespaces), forKey: "username")
        Keychain.set(password, for: "inbox_password")
    }
}

// MARK: - API

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class API {
    let settings: AppSettings
    init(_ settings: AppSettings) { self.settings = settings }

    private func data(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: settings.baseURL + path) else { throw APIError(message: "Invalid server URL") }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = method
        req.setValue(settings.authHeader, forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (body, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "No response from server") }
        if http.statusCode == 401 { throw APIError(message: "Wrong username or password") }
        if http.statusCode >= 400 {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let e = obj["error"] as? String { throw APIError(message: e) }
            throw APIError(message: "Server error \(http.statusCode)")
        }
        return body
    }

    func numbers() async throws -> [OurNumber] {
        try JSONDecoder().decode([OurNumber].self, from: try await data("/api/numbers"))
    }

    func conversations(box: String = "all") async throws -> [Conversation] {
        let q = box == "all" ? "" : "?box=\(encodeQuery(box))"
        return try JSONDecoder().decode([Conversation].self, from: try await data("/api/conversations\(q)"))
    }

    func thread(via: String, contact: String) async throws -> [Message] {
        let path = "/api/thread?via=\(encodeQuery(via))&with=\(encodeQuery(contact))"
        return try JSONDecoder().decode([Message].self, from: try await data(path))
    }

    func send(from: String, to: String, body: String) async throws {
        _ = try await data("/api/send", method: "POST",
                           json: ["from": from, "to": to, "body": body])
    }

    func sendMMS(from: String, to: String, body: String, imageData: Data, contentType: String) async throws {
        _ = try await data("/api/send-mms", method: "POST",
                           json: ["from": from, "to": to, "body": body,
                                  "image": imageData.base64EncodedString(),
                                  "content_type": contentType])
    }

    func sendFile(from: String, to: String, body: String, fileData: Data, filename: String) async throws {
        _ = try await data("/api/send-file", method: "POST",
                           json: ["from": from, "to": to, "body": body,
                                  "file": fileData.base64EncodedString(),
                                  "filename": filename])
    }

    func mediaData(_ path: String) async throws -> Data {
        try await data(path)
    }

    func markRead() async {
        _ = try? await data("/api/mark-read", method: "POST", json: [:])
    }

    func calls() async throws -> [CallRecord] {
        try JSONDecoder().decode([CallRecord].self, from: try await data("/api/calls"))
    }

    func voicemails() async throws -> [Voicemail] {
        try JSONDecoder().decode([Voicemail].self, from: try await data("/api/voicemails"))
    }

    func contacts() async throws -> [Contact] {
        try JSONDecoder().decode([Contact].self, from: try await data("/api/contacts"))
    }

    func saveContact(phone: String, name: String) async throws {
        _ = try await data("/api/contact", method: "POST", json: ["phone": phone, "name": name])
    }

    func deleteThread(via: String, contact: String) async throws {
        _ = try await data("/api/thread-delete", method: "POST", json: ["via": via, "with": contact])
    }

    func deleteMessage(id: Int) async throws {
        _ = try await data("/api/message-delete", method: "POST", json: ["id": id])
    }

    func deleteCall(uniqueid: String) async throws {
        _ = try await data("/api/call-delete", method: "POST", json: ["uniqueid": uniqueid])
    }

    func deleteVoicemail(ext: String, msgid: String) async throws {
        _ = try await data("/api/voicemail-delete", method: "POST", json: ["ext": ext, "msgid": msgid])
    }

    func voicemailAudio(ext: String, msgid: String) async throws -> Data {
        try await data("/api/voicemail/\(ext)/\(msgid)/audio")
    }

    func call(from: String, to: String) async throws {
        _ = try await data("/api/call", method: "POST", json: ["from": from, "to": to])
    }

    private func suggestion(from body: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let s = obj["suggestion"] as? String, !s.isEmpty else {
            throw APIError(message: "No suggestion returned")
        }
        return s
    }

    func suggestThreadReply(via: String, contact: String) async throws -> String {
        try suggestion(from: try await data("/api/suggest-reply", method: "POST",
                                            json: ["via": via, "with": contact]))
    }

    func suggestVoicemailReply(ext: String, msgid: String) async throws -> String {
        try suggestion(from: try await data("/api/suggest-vm", method: "POST",
                                            json: ["ext": ext, "msgid": msgid]))
    }
}
