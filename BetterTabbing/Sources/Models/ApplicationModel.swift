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

    // Resource usage (populated on demand, not part of equality/hash)
    var memoryBytes: UInt64 = 0

    // Extended metadata (lazy loaded)
    var browserTabs: [BrowserTabModel]?
    var ideProject: String?

    init(
        pid: pid_t,
        bundleIdentifier: String,
        name: String,
        icon: NSImage,
        windows: [WindowModel] = [],
        isActive: Bool = false,
        memoryBytes: UInt64 = 0
    ) {
        self.id = pid
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
        self.windows = windows
        self.isActive = isActive
        self.memoryBytes = memoryBytes
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

    /// Formatted memory string (e.g. "142 MB", "1.2 GB")
    var formattedMemory: String? {
        guard memoryBytes > 0 else { return nil }
        let mb = Double(memoryBytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        } else {
            return "\(Int(mb)) MB"
        }
    }
}

struct BrowserTabModel: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: String?
    let isActive: Bool
}
