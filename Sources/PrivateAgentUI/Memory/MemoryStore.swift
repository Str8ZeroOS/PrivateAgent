import Foundation

struct MemoryEntry: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var text: String
    var createdAt = Date()
}

/// A short, visible list of things the user asked the assistant to remember.
/// Stored on this device only (UserDefaults). Nothing is saved automatically:
/// entries come from "remember that ..." in chat or from Settings, and every
/// entry can be deleted. When memory is on, entries are added to the system
/// prompt of each conversation (and are sent to a cloud/private server with it).
enum MemoryStore {
    static let enabledKey = "memoryEnabled"
    private static let storeKey = "memoryEntries"
    static let maxEntries = 50
    static let maxLength = 300

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var entries: [MemoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [MemoryEntry]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    /// Looks like a password or API key. Those are never saved.
    static func looksSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("nvapi-") || lower.contains("password") || lower.contains("passcode") || lower.contains("api key") {
            return true
        }
        return text.range(of: "sk-[A-Za-z0-9]{16,}", options: .regularExpression) != nil
    }

    /// Adds one entry. Returns false (and saves nothing) if it is empty or looks like a secret.
    @discardableResult
    static func add(_ raw: String) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !looksSecret(text) else { return false }
        if text.count > maxLength { text = String(text.prefix(maxLength)) }
        var list = entries
        if list.contains(where: { $0.text.caseInsensitiveCompare(text) == .orderedSame }) { return true }
        list.append(MemoryEntry(text: text))
        if list.count > maxEntries { list.removeFirst(list.count - maxEntries) }
        save(list)
        return true
    }

    static func remove(at offsets: IndexSet) {
        var list = entries
        for i in offsets.sorted(by: >) where list.indices.contains(i) { list.remove(at: i) }
        save(list)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storeKey)
    }

    /// Saves the text after "remember that ..." / "remember: ..." / "remember this: ...".
    /// Plain questions like "remember when ..." are ignored on purpose.
    @discardableResult
    static func captureIfRequested(_ text: String) -> Bool {
        let pattern = "^\\s*(?:please\\s+)?remember\\s*(?:that\\b|this\\b\\s*:?|:)\\s*(.+)$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return false }
        return add(String(text[r]))
    }

    /// The system prompt plus the saved items (unchanged when memory is off or empty).
    static func augmented(_ base: String) -> String {
        guard isEnabled else { return base }
        let items = entries
        guard !items.isEmpty else { return base }
        let lines = items.map { "- " + $0.text }.joined(separator: "\n")
        return base + "\n\nThe user asked you to remember these things. Use them only when relevant, and do not list them unless asked:\n" + lines
    }
}