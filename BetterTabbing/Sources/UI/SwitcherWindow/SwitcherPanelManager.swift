import AppKit
import Combine

/// Manages multiple SwitcherPanel instances for multi-screen display
@MainActor
final class SwitcherPanelManager {
    static let shared = SwitcherPanelManager()

    /// Active panels keyed by screen identifier
    private var panels: [String: SwitcherPanel] = [:]

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupScreenObserver()
        setupClickOutsideHandler()
    }

    // MARK: - Screen Observation

    private func setupScreenObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenConfigurationChange()
            }
        }
    }

    private func handleScreenConfigurationChange() {
        let currentScreenIds = Set(NSScreen.screens.compactMap { screenIdentifier(for: $0) })
        let existingIds = Set(panels.keys)

        // Remove panels for disconnected screens
        let removedIds = existingIds.subtracting(currentScreenIds)
        for id in removedIds {
            panels[id]?.orderOut(nil)
            panels.removeValue(forKey: id)
            print("[SwitcherPanelManager] Removed panel for disconnected screen: \(id)")
        }

        // If panels are currently visible, add panels for new screens
        if AppState.shared.isVisible {
            let addedIds = currentScreenIds.subtracting(existingIds)
            for screen in NSScreen.screens {
                if let id = screenIdentifier(for: screen), addedIds.contains(id) {
                    let panel = createPanel(for: screen)
                    panels[id] = panel
                    panel.showOnScreen(skipStateUpdate: true)
                    print("[SwitcherPanelManager] Added panel for new screen: \(id)")
                }
            }
        }

        // Recenter existing panels (screen bounds may have changed)
        for panel in panels.values where panel.isVisible {
            panel.recenterOnAssociatedScreen()
        }
    }

    private func screenIdentifier(for screen: NSScreen) -> String? {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            return "\(number)"
        }
        // Fallback to frame origin
        return "\(Int(screen.frame.origin.x))_\(Int(screen.frame.origin.y))"
    }

    // MARK: - Panel Creation

    private func createPanel(for screen: NSScreen) -> SwitcherPanel {
        return SwitcherPanel(screen: screen)
    }

    private func ensurePanelsExist() {
        for screen in NSScreen.screens {
            guard let id = screenIdentifier(for: screen) else { continue }
            if panels[id] == nil {
                panels[id] = createPanel(for: screen)
            } else {
                // Update the screen reference in case it changed
                panels[id]?.updateAssociatedScreen(screen)
            }
        }
    }

    // MARK: - Show/Hide

    func showWithCachedData() {
        let startTime = CFAbsoluteTimeGetCurrent()

        ensurePanelsExist()

        // Update AppState ONCE
        let apps = WindowCache.shared.getCachedApplications()
        let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps
        AppState.shared.applications = finalApps
        AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.isVisible = true

        // Show all panels (without re-updating state)
        for panel in panels.values {
            panel.showOnScreen(skipStateUpdate: true)
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[SwitcherPanelManager] Shown \(panels.count) panels in \(Int(elapsed))ms with \(finalApps.count) apps")
    }

    func show() {
        ensurePanelsExist()

        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        AppState.shared.applications = apps
        AppState.shared.selectedAppIndex = apps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.isVisible = true

        for panel in panels.values {
            panel.showOnScreen(skipStateUpdate: true)
        }

        print("[SwitcherPanelManager] Shown \(panels.count) panels")
    }

    func hide() {
        for panel in panels.values {
            panel.hidePanel()
        }
        AppState.shared.reset()
        print("[SwitcherPanelManager] Hidden all \(panels.count) panels")
    }

    // MARK: - Navigation (state is shared via AppState)

    func selectNext() {
        AppState.shared.selectNextApp()
    }

    func selectPrevious() {
        AppState.shared.selectPreviousApp()
    }

    func selectNextWindow() {
        AppState.shared.selectNextWindow()
    }

    func selectPreviousWindow() {
        AppState.shared.selectPreviousWindow()
    }

    func activateSearch() {
        AppState.shared.isSearchActive = true
        // Make any panel key to receive keyboard input
        panels.values.first?.makeKey()
    }

    func confirmSelection() {
        guard let app = AppState.shared.selectedApp else {
            hide()
            NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)
            return
        }

        let windowIndex = AppState.shared.selectedWindowIndex

        // Hide first for responsiveness
        hide()

        // Notify that we confirmed
        NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)

        // Then switch
        if app.windows.indices.contains(windowIndex) {
            let window = app.windows[windowIndex]
            WindowSwitcher.shared.switchTo(window: window, in: app, windowIndex: windowIndex)
        } else {
            WindowSwitcher.shared.activate(app: app)
        }
    }

    // MARK: - Click Outside Detection

    private func setupClickOutsideHandler() {
        NotificationCenter.default.publisher(for: .clickOutsideDetected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self else { return }
                guard let location = notification.userInfo?["location"] as? NSPoint else { return }

                // Check if click is inside ANY panel
                let clickInsideAnyPanel = self.panels.values.contains { panel in
                    panel.isVisible && panel.frame.contains(location)
                }

                if !clickInsideAnyPanel {
                    print("[SwitcherPanelManager] Click outside all panels, dismissing")
                    NotificationCenter.default.post(name: .switcherDismissedByClickOutside, object: nil)
                    self.hide()
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let clickOutsideDetected = Notification.Name("clickOutsideDetected")
}
