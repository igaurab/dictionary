import Combine
import Foundation

/// Words the reader has saved, newest first.
///
/// Stored separately from `DictionaryViewModel.recents` because favourites
/// outlive the 100-entry recents window, but persisted the same way: a plain
/// string array written back to UserDefaults on every change.
@MainActor
final class FavoritesStore: ObservableObject {
    private static let storageKey = "favoriteWords"

    @Published private(set) var words: [String] {
        didSet { UserDefaults.standard.set(words, forKey: Self.storageKey) }
    }

    init() {
        words = UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? []
    }

    func isFavorite(_ word: String) -> Bool {
        let key = Self.key(word)
        return !key.isEmpty && words.contains { Self.key($0) == key }
    }

    /// Saves or unsaves a word. Re-saving an already-saved word moves it back to
    /// the top, matching how a repeat lookup moves a word up the recents list.
    func toggle(_ word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isFavorite(trimmed) {
            remove(trimmed)
        } else {
            words.insert(trimmed, at: 0)
        }
    }

    func remove(_ word: String) {
        let key = Self.key(word)
        guard !key.isEmpty else { return }
        words.removeAll { Self.key($0) == key }
    }

    /// Swipe-to-delete, which works in index space rather than by word.
    func remove(atOffsets offsets: IndexSet) {
        words.remove(atOffsets: offsets)
    }

    func removeAll() {
        words.removeAll()
    }

    /// Headwords are matched case-insensitively, so "Apple" and "apple" are the
    /// same favourite — the dictionary itself looks words up that way.
    private static func key(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
