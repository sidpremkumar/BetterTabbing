import CoreGraphics
import AppKit
import ApplicationServices

actor PermissionManager {
    static let shared = PermissionManager()

    enum Permission: String, CaseIterable {
        case inputMonitoring = "Input Monitoring"
        case accessibility = "Accessibility"
        case screenRecording = "Screen Recording"
    }

    struct Status {
        var inputMonitoring: Bool
        var accessibility: Bool
        var screenRecording: Bool

        var allGranted: Bool {
            inputMonitoring && accessibility && screenRecording
        }

        var description: String {
            """
            Input Monitoring: \(inputMonitoring ? "✓" : "✗")
            Accessibility: \(accessibility ? "✓" : "✗")
            Screen Recording: \(screenRecording ? "✓" : "✗")
            """
        }
    }

    func checkStatus() -> Status {
        Status(
            inputMonitoring: checkInputMonitoring(),
            accessibility: checkAccessibility(),
            screenRecording: checkScreenRecording()
        )
    }

    func requestPermissions() async {
        let status = checkStatus()

        if !status.inputMonitoring {
            requestInputMonitoring()
        }

        if !status.accessibility {
            requestAccessibility()
        }

        if !status.screenRecording {
            requestScreenRecording()
        }
    }

    // MARK: - Input Monitoring

    private func checkInputMonitoring() -> Bool {
        return CGPreflightListenEventAccess()
    }

    private func requestInputMonitoring() {
        let granted = CGRequestListenEventAccess()
        print("[PermissionManager] Input Monitoring request result: \(granted)")
    }

    // MARK: - Accessibility

    private func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    private func requestAccessibility() {
        // Create the prompt key string directly to avoid Swift 6 concurrency issues
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: true] as CFDictionary
        let _ = AXIsProcessTrustedWithOptions(options)
        print("[PermissionManager] Accessibility permission requested")
    }

    // MARK: - Screen Recording

    private func checkScreenRecording() -> Bool {
        // Test by attempting to get window names from another app
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        // Find a window from a different process
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for window in windowList {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != currentPID else {
                continue
            }

            // If we can get the window name for another process, we have permission
            if window[kCGWindowName as String] != nil {
                return true
            }
        }

        // If no window names were available, we likely don't have permission
        // But this could also mean no other windows exist, so we assume granted
        return windowList.count <= 1
    }

    private func requestScreenRecording() {
        // Trigger the permission dialog by attempting to capture screen content
        // This is done implicitly when CGWindowListCopyWindowInfo is called
        _ = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        print("[PermissionManager] Screen Recording permission requested (implicit)")
    }

    // MARK: - Open System Preferences

    func openSystemPreferences(for permission: Permission) {
        let urlString: String
        switch permission {
        case .inputMonitoring:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
