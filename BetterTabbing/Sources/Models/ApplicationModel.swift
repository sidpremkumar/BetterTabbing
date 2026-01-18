import AppKit
import CoreGraphics

struct ApplicationModel: Identifiable, Hashable {
    let id: pid_t
    let pid: pid_t
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    var windows: [WindowModel]
    let isActive: Bool

    // Extended metadata (lazy loaded)
    var browserTabs: [BrowserTabModel]?
    var ideProject: String?

    init(
        pid: pid_t,
        bundleIdentifier: String,
        name: String,
        icon: NSImage,
        windows: [WindowModel] = [],
        isActive: Bool = false
    ) {
        self.id = pid
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
        self.windows = windows
        self.isActive = isActive
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
    }

    static func == (lhs: ApplicationModel, rhs: ApplicationModel) -> Bool {
        lhs.pid == rhs.pid
    }

    // MARK: - Convenience

    var windowCount: Int {
        windows.count
    }

    var hasMultipleWindows: Bool {
        windows.count > 1
    }

    var primaryWindowTitle: String? {
        windows.first?.title
    }
}

struct BrowserTabModel: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: String?
    let isActive: Bool
}
