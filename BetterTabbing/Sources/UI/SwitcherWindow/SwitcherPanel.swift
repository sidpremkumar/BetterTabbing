import AppKit
import SwiftUI
import Combine

final class SwitcherPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        configure()
        setupHostingView()
        setupNotifications()
    }

    private func configure() {
        // Window level above everything except screen saver
        level = .popUpMenu

        // Appearance
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false  // Shadow is handled by SwiftUI view

        // Behavior
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true  // Allow becoming key when needed (for text input)

        // Appear on all spaces
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient
        ]

        // Animation
        animationBehavior = .utilityWindow
    }

    // Allow the panel to become key window (needed for TextField input)
    override var canBecomeKey: Bool { true }

    private func setupHostingView() {
        let switcherView = SwitcherView()
            .environmentObject(AppState.shared)

        hostingView = NSHostingView(rootView: AnyView(switcherView))
        contentView = hostingView
    }

    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .confirmSwitcherSelection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.confirmSelection()
            }
            .store(in: &cancellables)
    }

    // MARK: - Public Methods

    /// Show using already-cached data (called after quick-switch timeout)
    /// This is fully synchronous for maximum speed - uses lock-free cache read
    func showWithCachedData() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Use lock-free cached data (prefetch may still be running, that's OK)
        let apps = WindowCache.shared.getCachedApplications()

        // If no cached data yet, do a quick sync fetch (fallback)
        let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps

        AppState.shared.applications = finalApps
        AppState.shared.selectedAppIndex = 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.isVisible = true

        // Let SwiftUI calculate the content size
        hostingView?.layoutSubtreeIfNeeded()

        // Get the intrinsic size from the hosting view
        let fittingSize = hostingView?.fittingSize ?? CGSize(width: 600, height: 400)

        // Apply reasonable bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.8, 700)
        let panelSize = CGSize(
            width: min(max(fittingSize.width, 400), maxWidth),
            height: min(max(fittingSize.height, 200), maxHeight)
        )

        // Center on screen, slightly above center
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 50
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Show instantly (no fade for speed)
        alphaValue = 1
        makeKeyAndOrderFront(nil)

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[SwitcherPanel] Shown in \(Int(elapsed))ms with \(finalApps.count) apps")
    }

    /// Legacy show method (forces refresh) - synchronous
    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        AppState.shared.applications = apps
        AppState.shared.selectedAppIndex = 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.isVisible = true

        // Let SwiftUI calculate the content size
        hostingView?.layoutSubtreeIfNeeded()

        // Get the intrinsic size from the hosting view
        let fittingSize = hostingView?.fittingSize ?? CGSize(width: 600, height: 400)

        // Apply reasonable bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.8, 700)
        let panelSize = CGSize(
            width: min(max(fittingSize.width, 400), maxWidth),
            height: min(max(fittingSize.height, 200), maxHeight)
        )

        // Center on screen, slightly above center
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 50
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Show instantly
        alphaValue = 1
        makeKeyAndOrderFront(nil)

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()
        print("[SwitcherPanel] Shown")
    }

    func hide() {
        // Stop monitoring clicks
        stopClickOutsideMonitor()

        // Hide instantly for responsiveness
        alphaValue = 0
        orderOut(nil)
        AppState.shared.reset()

        print("[SwitcherPanel] Hidden")
    }

    private func startClickOutsideMonitor() {
        // Monitor for mouse clicks outside the panel
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return }

            // Check if the click is outside this panel
            let screenLocation = NSEvent.mouseLocation
            let panelFrame = self.frame

            if !panelFrame.contains(screenLocation) {
                print("[SwitcherPanel] Click outside detected, dismissing")
                DispatchQueue.main.async {
                    // Notify the event tap that we're dismissing
                    NotificationCenter.default.post(name: .switcherDismissedByClickOutside, object: nil)
                    self.hide()
                }
            }
        }
    }

    private func stopClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

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
        // Make the panel key to receive keyboard input
        makeKey()
    }

    func confirmSelection() {
        guard let app = AppState.shared.selectedApp else {
            hide()
            // Notify that we're done (so event tap updates its state)
            NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)
            return
        }

        let windowIndex = AppState.shared.selectedWindowIndex

        // Hide first for responsiveness
        hide()

        // Notify that we confirmed via mouse click (so event tap updates its state)
        // This prevents double-confirm when modifier is released after click
        NotificationCenter.default.post(name: .switcherConfirmedByMouseClick, object: nil)

        // Then switch synchronously
        if app.windows.indices.contains(windowIndex) {
            let window = app.windows[windowIndex]
            WindowSwitcher.shared.switchTo(window: window, in: app)
        } else {
            WindowSwitcher.shared.activate(app: app)
        }
    }
}
