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
        setupStateObservers()
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

        // Critical: Disable Auto Layout constraints for the hosting view
        // This prevents conflicts between NSPanel's frame-based layout and SwiftUI's layout system
        hostingView?.translatesAutoresizingMaskIntoConstraints = true
        hostingView?.autoresizingMask = [.width, .height]

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

    private func setupStateObservers() {
        // Observe search state changes to re-center panel
        AppState.shared.$isSearchActive
            .dropFirst()  // Skip initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)

        // Observe search query changes (for search results height)
        AppState.shared.$searchQuery
            .dropFirst()
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)

        // Observe selected app changes (for window list)
        AppState.shared.$selectedAppIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recenterIfVisible()
            }
            .store(in: &cancellables)
    }

    // MARK: - Size Calculation (matches SwitcherView)

    private func calculateCurrentSize() -> CGSize {
        let appState = AppState.shared
        let appCount = appState.filteredApplications.count
        let isSearchActive = appState.isSearchActive
        let searchQuery = appState.searchQuery

        // Check if showing search results
        let showSearchResults = isSearchActive && !searchQuery.isEmpty

        // Check if showing window list
        let selectedApp = appState.selectedApp
        let showWindowList = !showSearchResults && (selectedApp?.hasMultipleWindows ?? false)

        // Width calculation
        let width: CGFloat
        if showSearchResults {
            width = 480
        } else {
            let idealItemsPerRow = min(appCount, 8)
            let baseWidth = CGFloat(idealItemsPerRow) * 88 + 32
            width = min(max(baseWidth, 400), 720)
        }

        // Height calculation
        let searchBarHeight: CGFloat = isSearchActive ? 54 : 0

        let contentHeight: CGFloat
        if showSearchResults {
            let resultCount = min(appState.searchResults.count, 10)
            let resultsHeight = resultCount == 0 ? 80 : CGFloat(resultCount) * 44 + 24
            contentHeight = resultsHeight + 14
        } else {
            let itemsPerRow = max(1, Int((width - 32) / 88))
            let rows = appCount > 0 ? ceil(CGFloat(appCount) / CGFloat(itemsPerRow)) : 1
            let gridHeight = rows * 100 + 28
            let hintsHeight: CGFloat = 30
            let windowListHeight: CGFloat = showWindowList ? 70 : 0
            contentHeight = gridHeight + hintsHeight + windowListHeight
        }

        return CGSize(width: width, height: searchBarHeight + contentHeight)
    }

    private func recenterIfVisible() {
        guard isVisible, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let calculatedSize = calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(calculatedSize.width, maxWidth),
            height: min(calculatedSize.height, maxHeight)
        )

        // Center on screen, slightly above center
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 40
        )

        let newFrame = CGRect(origin: origin, size: panelSize)

        // Defer frame change to next run loop iteration to avoid constraint conflicts
        // during the current layout cycle
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }

            // Animate the frame change
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(newFrame, display: true)
            }
        }
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

        // Calculate size based on content
        let calculatedSize = calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(calculatedSize.width, maxWidth),
            height: min(calculatedSize.height, maxHeight)
        )

        // Center on screen, slightly above center for aesthetic
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 40
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Show instantly (no fade for speed)
        alphaValue = 1
        makeKeyAndOrderFront(nil)

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()

        let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        print("[SwitcherPanel] Shown in \(Int(elapsed))ms with \(finalApps.count) apps, size: \(Int(panelSize.width))x\(Int(panelSize.height))")
    }

    /// Legacy show method (forces refresh) - synchronous
    func show() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        AppState.shared.applications = apps
        AppState.shared.selectedAppIndex = 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.isVisible = true

        // Calculate size based on content
        let calculatedSize = calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(calculatedSize.width, maxWidth),
            height: min(calculatedSize.height, maxHeight)
        )

        // Center on screen, slightly above center
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 40
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
            WindowSwitcher.shared.switchTo(window: window, in: app, windowIndex: windowIndex)
        } else {
            WindowSwitcher.shared.activate(app: app)
        }
    }
}
