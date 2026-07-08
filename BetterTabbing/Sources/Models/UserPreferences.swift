import Foundation

struct UserPreferences: Codable {
    // Activation
    var activationModifier: ModifierKey = .command
    var useSystemShortcut: Bool = true  // If true, use CMD+TAB (replaces system) instead of OPTION+TAB

    // Behavior
    var showAllSpaces: Bool = false
    var showMinimizedWindows: Bool = true
    var hideSystemApps: Bool = true

    // Appearance
    var theme: Theme = .system
    var windowSize: WindowSize = .medium

    // Quit Hold
    var quitHoldDuration: Double = 2.0  // seconds (0.5 - 5.0)

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
