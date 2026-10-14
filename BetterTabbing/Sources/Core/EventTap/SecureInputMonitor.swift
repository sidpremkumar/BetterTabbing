import AppKit
import Carbon.HIToolbox
import Combine
@preconcurrency import UserNotifications

/// Watches macOS Secure Keyboard Entry. While any app holds it (e.g. Terminal's
/// "Secure Keyboard Entry" menu item), CGEventTaps receive no keystrokes, so the
/// switcher silently falls back to the native cmd+tab with no error anywhere.
/// This polls Carbon's IsSecureEventInputEnabled(), logs transitions with the
/// holding app, and exposes state for the menu bar warning.
@MainActor
final class SecureInputMonitor: ObservableObject {
    static let shared = SecureInputMonitor()

    /// True while another app holds Secure Keyboard Entry (event tap is deaf).
    @Published private(set) var isSecureInputActive = false
    /// Name of the app holding secure input, if it could be resolved.
    @Published private(set) var blockingAppName: String?

    private var timer: Timer?
    private let pollInterval: TimeInterval = 3.0
    /// Set once the notification for the current secure-input episode was posted.
    private var hasNotifiedThisEpisode = false

    private init() {}

    /// Begin polling. Safe to call repeatedly.
    func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 1.0
        timer = t
        DiagnosticLog.shared.log("[SecureInput] Monitoring started (poll every \(Int(pollInterval))s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let active = IsSecureEventInputEnabled()

        if active && !isSecureInputActive {
            isSecureInputActive = true
            hasNotifiedThisEpisode = false
            let holder = Self.secureInputHolder()
            blockingAppName = holder.name
            let holderDescription: String
            switch (holder.name, holder.pid) {
            case let (name?, pid?): holderDescription = "\(name) (pid \(pid))"
            case let (name?, nil):  holderDescription = name
            case let (nil, pid?):   holderDescription = "pid \(pid)"
            case (nil, nil):        holderDescription = "unknown app"
            }
            DiagnosticLog.shared.log("[SecureInput] Secure Keyboard Entry ENABLED by \(holderDescription) — event tap receives no keystrokes, cmd+tab falls back to the native switcher")
        } else if !active && isSecureInputActive {
            isSecureInputActive = false
            blockingAppName = nil
            hasNotifiedThisEpisode = false
            DiagnosticLog.shared.log("[SecureInput] Secure Keyboard Entry disabled — event tap functional again")
        } else if active && !hasNotifiedThisEpisode {
            // Still on after a full poll interval: a persistent hold (e.g. Terminal's
            // menu item), not a transient password field. Worth interrupting the user.
            hasNotifiedThisEpisode = true
            DiagnosticLog.shared.log("[SecureInput] Secure Keyboard Entry persisting — posting user notification")
            postUserNotification(holderName: blockingAppName)
        }
    }

    /// Resolve who holds secure input via the session dictionary's
    /// kCGSSessionSecureInputPID (private but long-stable key).
    private static func secureInputHolder() -> (pid: pid_t?, name: String?) {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pidValue = dict["kCGSSessionSecureInputPID"] as? Int else {
            return (nil, nil)
        }
        let pid = pid_t(pidValue)
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName
        return (pid, name)
    }

    /// One-shot banner so the failure is visible without opening the menu bar.
    /// UNUserNotificationCenter requires a real bundle; skip for bare-binary runs.
    private func postUserNotification(holderName: String?) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "BetterTabbing shortcuts blocked"
            content.body = "\(holderName ?? "Another app") turned on Secure Keyboard Entry, so the switcher can't see your keystrokes. Turn it off (e.g. Terminal ▸ Secure Keyboard Entry) to restore it."
            let request = UNNotificationRequest(
                identifier: "secure-input-active",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}
