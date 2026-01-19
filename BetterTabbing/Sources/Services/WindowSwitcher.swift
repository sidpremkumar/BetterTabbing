import AppKit
import ApplicationServices

/// Fast window switcher - no actor overhead
final class WindowSwitcher: @unchecked Sendable {
    static let shared = WindowSwitcher()

    private init() {}

    /// Activate an app (bring to front)
    func activate(app: ApplicationModel) {
        guard let runningApp = NSRunningApplication(processIdentifier: app.pid) else {
            print("[WindowSwitcher] Could not find running app for PID: \(app.pid)")
            return
        }

        // Check current frontmost app - if it's a "sticky" app like Warp, we may need to hide it first
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        let currentFrontmostName = currentFrontmost?.localizedName ?? "unknown"

        // Use Accessibility API to raise the window first
        let axApp = AXUIElementCreateApplication(app.pid)
        var windowsRef: CFTypeRef?
        var firstWindow: AXUIElement?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement],
           let window = windows.first {
            firstWindow = window
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        // Try activation
        var success = runningApp.activate()

        // If standard activate fails, try hiding the current app first then activating
        if !success {
            print("[WindowSwitcher] Standard activate failed (from \(currentFrontmostName)), hiding frontmost and retrying")
            currentFrontmost?.hide()
            usleep(10000)  // 10ms for hide to take effect
            success = runningApp.activate()
        }

        // If still failing, try NSWorkspace.open()
        if !success, let bundleURL = runningApp.bundleURL {
            print("[WindowSwitcher] Hide+activate failed, trying NSWorkspace.open()")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = false

            let semaphore = DispatchSemaphore(value: 0)
            var openSuccess = false

            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { app, error in
                openSuccess = (error == nil && app != nil)
                semaphore.signal()
            }

            _ = semaphore.wait(timeout: .now() + 0.1)
            success = openSuccess
        }

        // Last resort: AX focus
        if !success {
            print("[WindowSwitcher] All methods failed, using AX focus as last resort")
            let systemWide = AXUIElementCreateSystemWide()
            AXUIElementSetAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, axApp)
            if let window = firstWindow {
                AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
            }
            success = true  // Assume it worked
        }

        print("[WindowSwitcher] Activated \(app.name): \(success)")

        // Update cache order
        WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
    }

    /// Switch to a specific window within an app
    /// windowIndex is the index in the app.windows array for fallback matching
    func switchTo(window: WindowModel, in app: ApplicationModel, windowIndex: Int? = nil) {
        guard let runningApp = NSRunningApplication(processIdentifier: app.pid) else {
            print("[WindowSwitcher] Could not find running app for PID: \(app.pid)")
            return
        }

        let axWindows = AXWindowHelper.getOrderedAXWindows(for: app.pid)

        // Strategy 1: Try to find by window index (most reliable since we enumerate in AX order)
        if let index = windowIndex, index < axWindows.count {
            let axWindow = axWindows[index]
            print("[WindowSwitcher] Using window index \(index)")
            raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app)
            return
        }

        // Strategy 2: Try to find the window by CGWindowID
        if let axWindow = AXWindowHelper.getAXWindow(for: window.windowID, pid: app.pid) {
            print("[WindowSwitcher] Found window by ID \(window.windowID)")
            raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app)
            return
        }

        print("[WindowSwitcher] Could not find window by ID \(window.windowID), trying title match")

        // Strategy 3: Fall back to title matching
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)

            if let title = titleRef as? String, title == window.title {
                raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app)
                return
            }
        }

        // Strategy 4: Try partial title match (for truncated titles)
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)

            if let title = titleRef as? String, !title.isEmpty, !window.title.isEmpty,
               (title.hasPrefix(window.title) || window.title.hasPrefix(title) ||
                title.contains(window.title) || window.title.contains(title)) {
                print("[WindowSwitcher] Found window by partial title match: '\(title)'")
                raiseAndActivate(axWindow: axWindow, window: window, runningApp: runningApp, app: app)
                return
            }
        }

        print("[WindowSwitcher] Window not found by ID or title, activating first window")

        // Strategy 5: Just activate the first window
        if let firstWindow = axWindows.first {
            AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
        }

        let activated = runningApp.activate()
        print("[WindowSwitcher] Activated \(app.name): \(activated)")

        if activated {
            WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
        }
    }

    /// Helper to raise a window and activate the app
    private func raiseAndActivate(axWindow: AXUIElement, window: WindowModel, runningApp: NSRunningApplication, app: ApplicationModel) {
        // Unminimize if needed
        if window.isMinimized {
            var minimizedRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minimizedRef)
            if let isMinimized = minimizedRef as? Bool, isMinimized {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
        }

        // Raise the window
        let raiseResult = AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        print("[WindowSwitcher] Raised window '\(window.title)': \(raiseResult == .success)")

        // Activate the app
        let activated = runningApp.activate()
        print("[WindowSwitcher] Activated \(app.name): \(activated)")

        // Update cache order
        if activated {
            WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
        }
    }

    func switchToWindow(byID windowID: CGWindowID, pid: pid_t) {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            print("[WindowSwitcher] Could not find running app for PID: \(pid)")
            return
        }

        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              let firstWindow = windows.first else {
            runningApp.activate()
            return
        }

        // Raise the first window (ideally we'd match by CGWindowID but that requires private API)
        AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
        runningApp.activate()
    }
}
