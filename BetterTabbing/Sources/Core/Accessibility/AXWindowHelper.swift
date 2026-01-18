import ApplicationServices
import AppKit

/// Helper for fetching window information via Accessibility API
/// This works with Accessibility permission (doesn't require Screen Recording)
final class AXWindowHelper {

    /// Get window titles for a given process ID using Accessibility API
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
            // Get window title
            var titleRef: CFTypeRef?
            let titleResult = AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)

            let title: String
            if titleResult == .success, let titleString = titleRef as? String, !titleString.isEmpty {
                title = titleString
            } else {
                // Try getting the document name as fallback
                var docRef: CFTypeRef?
                let docResult = AXUIElementCopyAttributeValue(axWindow, kAXDocumentAttribute as CFString, &docRef)
                if docResult == .success, let docPath = docRef as? String {
                    title = (docPath as NSString).lastPathComponent
                } else {
                    continue // Skip windows without titles
                }
            }

            // Try to get the CGWindowID for this AXUIElement
            // This is a private API but commonly used
            var windowID: CGWindowID = 0
            let idResult = _AXUIElementGetWindow(axWindow, &windowID)

            if idResult == .success && windowID != 0 {
                result[windowID] = title
            }
        }

        return result
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
