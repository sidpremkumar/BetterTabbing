import Foundation

struct UserPreferences: Codable {
    // Activation
    var activationModifier: ModifierKey = .option
    var useSystemShortcut: Bool = false  // If true, use CMD+TAB instead of OPTION+TAB

    // Behavior
    var showAllSpaces: Bool = false
    var showMinimizedWindows: Bool = true
    var hideSystemApps: Bool = true

    // Appearance
    var theme: Theme = .system
    var windowSize: WindowSize = .medium

    // Launch
    var launchAtLogin: Bool = false

    // Excluded Apps
    var excludedBundleIDs: [String] = []

    enum Theme: String, Codable, CaseIterable {
        case system
        case light
        case dark

        var displayName: String {
            rawValue.capitalized
        }
    }

    enum WindowSize: String, Codable, CaseIterable {
        case compact
        case medium
        case large

        var dimensions: CGSize {
            switch self {
            case .compact: return CGSize(width: 500, height: 300)
            case .medium: return CGSize(width: 680, height: 400)
            case .large: return CGSize(width: 860, height: 500)
            }
        }

        var displayName: String {
            rawValue.capitalized
        }
    }

    // MARK: - Persistence

    private static let key = "BetterTabbingPreferences"

    static func load() -> UserPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(UserPreferences.self, from: data) else {
            return UserPreferences()
        }
        return prefs
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: UserPreferences.key)
    }
}
