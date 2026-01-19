import CoreGraphics
import AppKit
import ApplicationServices

final class WindowEnumerator {

    struct EnumerationOptions {
        var includeMinimized: Bool = true
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

    /// Enumerate windows using Accessibility API as the primary source
    /// This is more reliable for window switching since we use AX to raise windows
    func enumerateGroupedByApp(options: EnumerationOptions = .default) -> [ApplicationModel] {
        // Get all running apps with regular activation policy (visible in Dock)
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bundleID = app.bundleIdentifier else { return false }
            return app.activationPolicy == .regular && !skipBundleIDs.contains(bundleID)
        }

        var applications: [ApplicationModel] = []

        for app in runningApps {
            guard let name = app.localizedName,
                  let bundleIdentifier = app.bundleIdentifier else {
                continue
            }

            let pid = app.processIdentifier
            let axApp = AXUIElementCreateApplication(pid)

            // Get windows from Accessibility API
            var windowsRef: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

            // If AX fails or returns empty, include the app with a synthetic window
            // This handles apps like Steam/games that may not fully support Accessibility
            let axWindows = (axResult == .success) ? (windowsRef as? [AXUIElement]) ?? [] : []

            if axResult != .success {
                print("[WindowEnumerator] AX failed for \(name) (error: \(axResult.rawValue)), using synthetic window")
            } else if axWindows.isEmpty {
                print("[WindowEnumerator] AX returned empty windows for \(name), using synthetic window")
            }

            var windows: [WindowInfo] = []

            for axWindow in axWindows {
                // Get window ID
                var windowID: CGWindowID = 0
                let idResult = _AXUIElementGetWindow(axWindow, &windowID)

                // Get title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String

                // Get position and size
                var positionRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionRef)
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)

                var position = CGPoint.zero
                var size = CGSize.zero

                if let posValue = positionRef {
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
                }
                if let sizeValue = sizeRef {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }

                // Skip tiny windows
                if size.width < options.minimumWidth || size.height < options.minimumHeight {
                    continue
                }

                // Check if minimized
                var minimizedRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
                let isMinimized = (minimizedRef as? Bool) ?? false

                if isMinimized && !options.includeMinimized {
                    continue
                }

                // Get subrole to filter out non-standard windows
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String

                // Skip known non-window subroles (like system overlays)
                // Be permissive - allow windows with no subrole or unknown subroles
                if let subrole = subrole {
                    let invalidSubroles = ["AXSystemDialog", "AXSheet", "AXDrawer", "AXUnknown"]
                    if invalidSubroles.contains(subrole) {
                        continue
                    }
                }

                // Use a valid window ID, or generate a unique one based on index
                let finalWindowID: CGWindowID
                if idResult == .success && windowID != 0 {
                    finalWindowID = windowID
                } else {
                    // Generate a pseudo-ID from PID and window index
                    finalWindowID = CGWindowID(pid) << 16 | CGWindowID(windows.count)
                }

                windows.append(WindowInfo(
                    windowID: finalWindowID,
                    ownerPID: pid,
                    ownerName: name,
                    windowName: title,
                    bounds: CGRect(origin: position, size: size),
                    isOnScreen: !isMinimized,
                    isMinimized: isMinimized,
                    spaceID: nil
                ))
            }

            let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()

            // If no windows found through AX, create a synthetic window
            // This ensures apps like Steam/games still appear in the switcher
            if windows.isEmpty {
                let syntheticWindow = WindowInfo(
                    windowID: CGWindowID(pid),
                    ownerPID: pid,
                    ownerName: name,
                    windowName: name,  // Use app name as window title
                    bounds: .zero,
                    isOnScreen: true,
                    isMinimized: false,
                    spaceID: nil
                )
                windows.append(syntheticWindow)
            }

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
