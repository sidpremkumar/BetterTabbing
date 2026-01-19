import ApplicationServices
import AppKit

/// Helper for fetching window information via Accessibility API
/// This works with Accessibility permission (doesn't require Screen Recording)
final class AXWindowHelper {

    /// Struct containing both title and the AX element for later use
    struct WindowInfo {
        let title: String
        let axElement: AXUIElement
    }

    /// Get window titles for a given process ID using Accessibility API
    /// Returns both titles mapped by CGWindowID and a list of AX elements for windows we couldn't map
    static func getWindowTitles(for pid: pid_t) -> [CGWindowID: String] {
        var result: [CGWindowID: String] = [:]

        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        let windowsResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)

        guard windowsResult == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return result
        }

        for axWindow in windows {
            // Get window title using multiple strategies
            let title = getWindowTitle(for: axWindow)
            guard let title = title, !title.isEmpty else {
                continue
            }

            // Try to get the CGWindowID for this AXUIElement
            var windowID: CGWindowID = 0
            let idResult = _AXUIElementGetWindow(axWindow, &windowID)

            if idResult == .success && windowID != 0 {
                result[windowID] = title
            }
        }

        return result
    }

    /// Get the best available title for a window using multiple strategies
    private static func getWindowTitle(for axWindow: AXUIElement) -> String? {
        // Strategy 1: Standard title attribute
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, !title.isEmpty {
            return title
        }

        // Strategy 2: Document attribute (file path)
        var docRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef) == .success,
           let docPath = docRef as? String, !docPath.isEmpty {
            return (docPath as NSString).lastPathComponent
        }

        // Strategy 3: Description attribute
        var descRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXDescriptionAttribute as CFString, &descRef) == .success,
           let desc = descRef as? String, !desc.isEmpty {
            return desc
        }

        // Strategy 4: Role description
        var roleDescRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axWindow, kAXRoleDescriptionAttribute as CFString, &roleDescRef) == .success,
           let roleDesc = roleDescRef as? String, !roleDesc.isEmpty {
            return roleDesc
        }

        return nil
    }

    /// Get the AXUIElement for a specific window by CGWindowID
    static func getAXWindow(for windowID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for axWindow in windows {
            var axWindowID: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &axWindowID) == .success && axWindowID == windowID {
                return axWindow
            }
        }

        return nil
    }

    /// Get all AX windows for a PID, ordered by position (for fallback matching)
    static func getOrderedAXWindows(for pid: pid_t) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return []
        }

        return windows
    }

    /// Get window titles only for specific PIDs - runs in PARALLEL for speed
    static func getWindowTitles(for pids: Set<pid_t>) -> [CGWindowID: String] {
        // Check if we have accessibility permission first
        guard AXIsProcessTrusted() else {
            return [:]
        }

        // For small number of PIDs, just do it serially (overhead not worth it)
        if pids.count <= 3 {
            var allTitles: [CGWindowID: String] = [:]
            for pid in pids {
                let titles = getWindowTitles(for: pid)
                allTitles.merge(titles) { _, new in new }
            }
            return allTitles
        }

        // For larger counts, run in parallel
        let lock = NSLock()
        var allTitles: [CGWindowID: String] = [:]

        DispatchQueue.concurrentPerform(iterations: pids.count) { index in
            let pid = Array(pids)[index]
            let titles = getWindowTitles(for: pid)

            lock.lock()
            allTitles.merge(titles) { _, new in new }
            lock.unlock()
        }

        return allTitles
    }
}

// Private API declaration for getting CGWindowID from AXUIElement
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError
