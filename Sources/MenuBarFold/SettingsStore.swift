import Foundation

/// UserDefaults-backed settings.
@MainActor
final class SettingsStore {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    /// Persistent IDs of items the user folded.
    var foldedIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "foldedIDs") ?? []) }
        set { defaults.set(Array(newValue), forKey: "foldedIDs") }
    }

    /// Seconds before a temporarily shown item is moved back.
    var tempShowInterval: Double {
        get { defaults.object(forKey: "tempShowInterval") as? Double ?? 15 }
        set { defaults.set(newValue, forKey: "tempShowInterval") }
    }

    /// Whether we've already placed the divider at the left edge once.
    var hasPlacedDividerOnce: Bool {
        get { defaults.bool(forKey: "hasPlacedDividerOnce") }
        set { defaults.set(newValue, forKey: "hasPlacedDividerOnce") }
    }
}
