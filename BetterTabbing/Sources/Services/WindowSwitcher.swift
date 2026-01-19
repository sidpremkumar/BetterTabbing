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

        // Use Accessibility API to raise the window first - this is more reliable
        // especially for apps like Warp that may interfere with direct activation
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

        // If standard activate fails, try alternative methods
        if !success {
            print("[WindowSwitcher] Standard activate failed, retrying with delay")
            // Small delay can help with race conditions
            usleep(5000)  // 5ms
            success = runningApp.activate()
        }

        // If still failing, use AX API to set focused application
        if !success {
            print("[WindowSwitcher] Retry failed, using AX focus")
            let systemWide = AXUIElementCreateSystemWide()
            let axResult = AXUIElementSetAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, axApp)
            if axResult == .success {
                success = true
                // Also try to focus the main window
                if let window = firstWindow {
                    AXUIElementSetAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, window)
                }
            }
        }

        print("[WindowSwitcher] Activated \(app.name): \(success)")

        // Update cache order so next quick switch works correctly (fast, no re-enumeration)
        // Pass fromOurSwitch=true to suppress the duplicate notification
        WindowCache.shared.moveAppToFront(pid: app.pid, fromOurSwitch: true)
    }

    /// Switch to a specific window within an app
    func switchTo(window: WindowModel, in app: ApplicationModel) {
        guard let runningApp = NSRunningApplication(processIdentifier: app.pid) else {
            print("[WindowSwitcher] Could not find running app for PID: \(app.pid)")
            return
        }

        // Get the AXUIElement for the application
        let axApp = AXUIElementCreateApplication(app.pid)

        // Find and raise the specific window
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success,
              let windows = windowsRef as? [AXUIElement] else {
            // Fallback to just activating the app
            print("[WindowSwitcher] Could not get windows, falling back to app activation")
            runningApp.activate()
            return
        }

        // Find matching window by title
        var foundWindow = false
        for axWindow in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)

            if let title = titleRef as? String, title == window.title {
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
                foundWindow = raiseResult == .success
                print("[WindowSwitcher] Raised window '\(title)': \(foundWindow)")
                break
            }
        }

        if !foundWindow {
            print("[WindowSwitcher] Window not found by title, activating first window")
            // Try to raise the first window
            if let firstWindow = windows.first {
                AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
            }
        }

        // Activate the app
        let activated = runningApp.activate()
        print("[WindowSwitcher] Activated \(app.name): \(activated)")

        // Update cache order so next quick switch works correctly (fast, no re-enumeration)
        // Pass fromOurSwitch=true to suppress the duplicate notification
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
