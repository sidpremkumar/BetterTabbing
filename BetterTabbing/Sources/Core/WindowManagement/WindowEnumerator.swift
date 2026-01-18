import CoreGraphics
import AppKit

final class WindowEnumerator {

    struct EnumerationOptions {
        var includeMinimized: Bool = true
        var includeAllSpaces: Bool = false
        var excludeDesktopElements: Bool = true
        var minimumWidth: CGFloat = 50
        var minimumHeight: CGFloat = 50

        static let `default` = EnumerationOptions()
    }

    // Bundle IDs to skip
    private let skipBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.SystemUIServer"
    ]

    /// Intermediate struct for first pass (before AX enrichment)
    private struct RawWindowInfo {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let ownerName: String
        let cgWindowName: String?
        let bounds: CGRect
        let isOnScreen: Bool
    }

    func enumerate(options: EnumerationOptions = .default) -> [WindowInfo] {
        var cgOptions: CGWindowListOption = []

        if options.excludeDesktopElements {
            cgOptions.insert(.excludeDesktopElements)
        }

        if !options.includeAllSpaces {
            cgOptions.insert(.optionOnScreenOnly)
        }

        guard let windowList = CGWindowListCopyWindowInfo(cgOptions, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // First pass: collect basic window info and PIDs
        var rawWindows: [RawWindowInfo] = []
        var pidsWithWindows: Set<pid_t> = []

        for dict in windowList {
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            if layer != 0 {
                continue  // Normal windows only (layer 0)
            }

            // Get bounds and check minimum size
            let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = boundsDict["Width"] ?? 0
            let height = boundsDict["Height"] ?? 0

            if width < options.minimumWidth || height < options.minimumHeight {
                continue
            }

            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let cgWindowName = dict[kCGWindowName as String] as? String

            rawWindows.append(RawWindowInfo(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                cgWindowName: cgWindowName,
                bounds: CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0, width: width, height: height),
                isOnScreen: dict[kCGWindowIsOnscreen as String] as? Bool ?? false
            ))
            pidsWithWindows.insert(ownerPID)
        }

        // Second pass: get AX window titles only for PIDs that have windows (runs in parallel)
        let axWindowTitles = AXWindowHelper.getWindowTitles(for: pidsWithWindows)

        // Build final WindowInfo with enriched titles
        return rawWindows.map { raw in
            let windowName: String?
            if let axTitle = axWindowTitles[raw.windowID], !axTitle.isEmpty {
                windowName = axTitle
            } else if let cgName = raw.cgWindowName, !cgName.isEmpty {
                windowName = cgName
            } else {
                windowName = nil
            }

            return WindowInfo(
                windowID: raw.windowID,
                ownerPID: raw.ownerPID,
                ownerName: raw.ownerName,
                windowName: windowName,
                bounds: raw.bounds,
                isOnScreen: raw.isOnScreen,
                isMinimized: !raw.isOnScreen && options.includeMinimized,
                spaceID: nil
            )
        }
    }

    func enumerateGroupedByApp(options: EnumerationOptions = .default) -> [ApplicationModel] {
        let windows = enumerate(options: options)

        // Group windows by PID
        var appWindows: [pid_t: [WindowInfo]] = [:]
        for window in windows {
            appWindows[window.ownerPID, default: []].append(window)
        }

        // Create application models
        var applications: [ApplicationModel] = []

        for (pid, windows) in appWindows {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let name = app.localizedName,
                  let bundleIdentifier = app.bundleIdentifier else {
                continue
            }

            // Skip system apps
            if skipBundleIDs.contains(bundleIdentifier) {
                continue
            }

            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

            applications.append(ApplicationModel(
                pid: pid,
                bundleIdentifier: bundleIdentifier,
                name: name,
                icon: icon,
                windows: windows.map { WindowModel(from: $0) },
                isActive: app.isActive
            ))
        }

        // Sort: active app first, then alphabetically by name
        return applications.sorted { app1, app2 in
            if app1.isActive && !app2.isActive { return true }
            if !app1.isActive && app2.isActive { return false }
            return app1.name.localizedCaseInsensitiveCompare(app2.name) == .orderedAscending
        }
    }
}
