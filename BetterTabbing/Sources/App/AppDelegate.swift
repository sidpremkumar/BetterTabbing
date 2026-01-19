import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var eventTap: KeyboardEventTap?
    private var switcherPanel: SwitcherPanel?
    private var preferencesWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        // Check/request permissions
        Task { @MainActor in
            let status = await PermissionManager.shared.checkStatus()
            if !status.allGranted {
                await PermissionManager.shared.requestPermissions()
            }
        }

        // Initialize event tap
        setupEventTap()

        // Create switcher panel (hidden initially)
        switcherPanel = SwitcherPanel()

        // Pre-warm the cache on startup so first activation is fast
        WindowCache.shared.prefetchAsync()
        WindowCache.shared.startMonitoring()

        print("[BetterTabbing] App initialized successfully")
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTap?.disable()
        print("[BetterTabbing] App terminating")
    }

    private func setupEventTap() {
        eventTap = KeyboardEventTap()

        eventTap?.onShortcutTriggered
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleShortcutEvent(event)
                }
            }
            .store(in: &cancellables)

        // Listen for click-outside-to-dismiss notifications
        NotificationCenter.default.publisher(for: .switcherDismissedByClickOutside)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.setSwitcherVisible(false)
                }
            }
            .store(in: &cancellables)

        // Listen for mouse-click confirmation notifications
        // This prevents double-confirm when modifier is released after clicking
        NotificationCenter.default.publisher(for: .switcherConfirmedByMouseClick)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.eventTap?.setSwitcherVisible(false)
                }
            }
            .store(in: &cancellables)

        // Listen for activation modifier changes from preferences
        NotificationCenter.default.publisher(for: .activationModifierChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                MainActor.assumeIsolated {
                    if let modifier = notification.userInfo?["modifier"] as? ModifierKey {
                        self?.eventTap?.setActivationModifier(modifier)
                        print("[BetterTabbing] Activation modifier changed to: \(modifier.symbol)")
                    }
                }
            }
            .store(in: &cancellables)

        // Apply saved preference for activation modifier
        let savedPrefs = UserPreferences.load()
        let modifier: ModifierKey = savedPrefs.useSystemShortcut ? .command : .option
        eventTap?.setActivationModifier(modifier)
        print("[BetterTabbing] Loaded activation modifier: \(modifier.symbol)")

        // Listen for open preferences notification
        NotificationCenter.default.publisher(for: .openPreferences)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    print("[BetterTabbing] Opening preferences window")
                    self?.showPreferencesWindow()
                }
            }
            .store(in: &cancellables)

        print("[BetterTabbing] Event tap configured")
    }

    private func showPreferencesWindow() {
        // If window exists and is visible, just bring it to front
        if let window = preferencesWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create new preferences window
        let preferencesView = PreferencesView()
            .environmentObject(AppState.shared)

        let hostingController = NSHostingController(rootView: preferencesView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "BetterTabbing Preferences"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 320))
        window.center()
        window.isReleasedWhenClosed = false

        preferencesWindow = window

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[BetterTabbing] Preferences window shown")
    }

    private func handleShortcutEvent(_ event: ShortcutEvent) {
        print("[BetterTabbing] Shortcut event: \(event)")

        switch event {
        case .activationStarted:
            // Pre-fetch window data on background thread (non-blocking)
            WindowCache.shared.prefetchAsync()
        case .showSwitcher:
            switcherPanel?.showWithCachedData()
            eventTap?.setSwitcherVisible(true)
        case .cycleNext:
            switcherPanel?.selectNext()
        case .cyclePrevious:
            switcherPanel?.selectPrevious()
        case .cycleWindowNext:
            switcherPanel?.selectNextWindow()
        case .cycleWindowPrevious:
            switcherPanel?.selectPreviousWindow()
        case .activateSearch:
            switcherPanel?.activateSearch()
            eventTap?.setSearchModeActive(true)
        case .confirm:
            switcherPanel?.confirmSelection()
            eventTap?.setSwitcherVisible(false)
        case .dismiss:
            switcherPanel?.hide()
            eventTap?.setSwitcherVisible(false)
        case .navigateUp:
            // Navigate up in search results (same as selectPrevious)
            switcherPanel?.selectPrevious()
        case .navigateDown:
            // Navigate down in search results (same as selectNext)
            switcherPanel?.selectNext()
        case .navigateRowUp:
            // Move to row above in the app grid
            AppState.shared.selectAppInRowAbove()
        case .navigateRowDown:
            // Move to row below in the app grid
            AppState.shared.selectAppInRowBelow()
        case .quickSwitch:
            // Quick switch to previous app without showing UI
            switcherPanel?.hide()
            eventTap?.setSwitcherVisible(false)
            performQuickSwitch()
        }
    }

    private func performQuickSwitch() {
        // Use cached data (lock-free read) - don't wait for any prefetch
        let apps = WindowCache.shared.getCachedApplications()

        // Switch to the second app (index 1) which is the "previous" app
        // The list is ordered by recent usage, so index 0 is current, index 1 is previous
        guard apps.count > 1 else {
            print("[BetterTabbing] Quick switch: Not enough apps (have \(apps.count))")
            return
        }

        let previousApp = apps[1]
        print("[BetterTabbing] Quick switch to: \(previousApp.name)")

        // Activate synchronously for speed
        WindowSwitcher.shared.activate(app: previousApp)
    }
}
