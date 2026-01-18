import CoreGraphics

struct WindowModel: Identifiable, Hashable {
    let id: CGWindowID
    let windowID: CGWindowID
    let title: String
    let bounds: CGRect
    let isMinimized: Bool
    let isOnScreen: Bool
    let spaceID: Int?

    // Extended metadata
    var subtitle: String?

    init(
        windowID: CGWindowID,
        title: String,
        bounds: CGRect = .zero,
        isMinimized: Bool = false,
        isOnScreen: Bool = true,
        spaceID: Int? = nil,
        subtitle: String? = nil
    ) {
        self.id = windowID
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.isMinimized = isMinimized
        self.isOnScreen = isOnScreen
        self.spaceID = spaceID
        self.subtitle = subtitle
    }

    init(from info: WindowInfo) {
        self.id = info.windowID
        self.windowID = info.windowID
        // Use window name if available, otherwise fall back to app name
        self.title = info.windowName ?? info.ownerName
        self.bounds = info.bounds
        self.isMinimized = info.isMinimized
        self.isOnScreen = info.isOnScreen
        self.spaceID = info.spaceID
        self.subtitle = nil
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }

    static func == (lhs: WindowModel, rhs: WindowModel) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

struct WindowInfo {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let windowName: String?
    let bounds: CGRect
    let isOnScreen: Bool
    let isMinimized: Bool
    let spaceID: Int?
}
