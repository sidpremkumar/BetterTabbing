import AppKit
import SwiftUI
import Combine

final class SwitcherPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?
    private var cancellables = Set<AnyCancellable>()
    private var clickOutsideMonitor: Any?

    /// The Y position of the top of the app grid (used to anchor expansions)
    private var gridTopY: CGFloat = 0

    /// The screen this panel is associated with (for multi-screen support)
    private(set) var associatedScreen: NSScreen?

    init(screen: NSScreen? = nil) {
        self.associatedScreen = screen
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

    /// Update the associated screen (used when screen configuration changes)
    func updateAssociatedScreen(_ screen: NSScreen) {
        self.associatedScreen = screen
    }

    private func configure() {
        // Window level above everything except screen saver
        level = .popUpMenu

        // Appearance
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true  // Use native macOS window shadow

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

        // Observe selected app changes (for window list) - resize without animation
        AppState.shared.$selectedAppIndex
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resizeForWindowList()
            }
            .store(in: &cancellables)

        // Observe resource monitor toggle to re-center panel
        AppState.shared.$isResourceMonitorActive
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
        } else if appState.isResourceMonitorActive {
            width = 420
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
        } else if appState.isResourceMonitorActive {
            // Resource monitor: bar chart (~100) + header (~20) + entries + hints + padding
            let entryCount = min(appState.resourceEntries.count, 15)
            let chartHeight: CGFloat = 110  // Bar chart area
            let entriesHeight = entryCount == 0 ? 80 : CGFloat(entryCount) * 30 + 24
            let hintsHeight: CGFloat = 30
            contentHeight = chartHeight + entriesHeight + hintsHeight + 14
        } else {
            // Each tile: 64px icon + 6px spacing + ~14px text + 12px padding = ~96px
            // Grid spacing: 6px between rows
            let itemsPerRow = max(1, Int((width - 32) / 88))
            let rows = appCount > 0 ? ceil(CGFloat(appCount) / CGFloat(itemsPerRow)) : 1
            let tileHeight: CGFloat = 96
            let gridSpacing: CGFloat = 6
            let gridHeight = rows * tileHeight + (rows - 1) * gridSpacing + 28  // +28 for vertical padding
            let hintsHeight: CGFloat = 30
            let windowListHeight: CGFloat = showWindowList ? 70 : 0
            contentHeight = gridHeight + hintsHeight + windowListHeight
        }

        // No extra padding needed - native NSPanel shadow extends beyond frame automatically
        return CGSize(width: width, height: searchBarHeight + contentHeight)
    }

    private func recenterIfVisible() {
        guard isVisible, let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Keep the top of the grid anchored - the panel grows/shrinks from the top
        // When search bar appears, panel grows upward (top goes up)
        // The grid stays at gridTopY
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: gridTopY - panelSize.height  // Anchor to the stored grid top position
        )

        let newFrame = CGRect(origin: origin, size: panelSize)

        // Defer frame change to next run loop iteration to avoid constraint conflicts
        // during the current layout cycle
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isVisible else { return }

            // Animate the frame change for search bar
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(newFrame, display: true)
            }
        }
    }

    /// Resize panel for window list without animation - keeps top anchored, grows downward instantly
    private func resizeForWindowList() {
        guard isVisible, let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Keep top anchored - only the bottom changes
        let currentTop = frame.origin.y + frame.size.height
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: currentTop - panelSize.height  // Keep top fixed, grow downward
        )

        // Set frame instantly (no animation) - SwiftUI will animate the content
        setFrame(CGRect(origin: origin, size: panelSize), display: true)
    }

    // MARK: - Public Methods

    /// Show using already-cached data (called after quick-switch timeout)
    /// This is fully synchronous for maximum speed - uses lock-free cache read
    func showWithCachedData() {
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Use lock-free cached data (prefetch may still be running, that's OK)
        let apps = WindowCache.shared.getCachedApplications()

        // If no cached data yet, do a quick sync fetch (fallback)
        let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps

        AppState.shared.applications = finalApps
        // Select index 1 (previous app) by default, since index 0 is the current frontmost app
        AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.isVisible = true

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Center on screen, slightly above center for aesthetic
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 40
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point (top of panel since no search bar initially)
        gridTopY = origin.y + panelSize.height

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
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let apps = WindowCache.shared.getApplicationsSync(forceRefresh: true)
        AppState.shared.applications = apps
        // Select index 1 (previous app) by default, since index 0 is the current frontmost app
        AppState.shared.selectedAppIndex = apps.count > 1 ? 1 : 0
        AppState.shared.selectedWindowIndex = 0
        AppState.shared.isVisible = true

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Center on screen, slightly above center
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 40
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point (top of panel since no search bar initially)
        gridTopY = origin.y + panelSize.height

        // Show instantly
        alphaValue = 1
        makeKeyAndOrderFront(nil)

        // Start monitoring for clicks outside the panel
        startClickOutsideMonitor()
        print("[SwitcherPanel] Shown with size: \(Int(panelSize.width))x\(Int(panelSize.height))")
    }

    /// Show panel on its associated screen (used by SwitcherPanelManager for multi-screen display)
    /// - Parameters:
    ///   - skipStateUpdate: If true, assumes AppState is already updated by the manager
    ///   - makeKey: If true, this panel becomes the key window (should be true for exactly ONE
    ///     panel — the one on the screen the user is looking at — so keyboard/search input lands there).
    ///     Mirror panels on other screens are ordered front without stealing key status.
    func showOnScreen(skipStateUpdate: Bool = false, makeKey: Bool = true) {
        guard let screen = associatedScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        if !skipStateUpdate {
            let apps = WindowCache.shared.getCachedApplications()
            let finalApps = apps.isEmpty ? WindowCache.shared.getApplicationsSync(forceRefresh: true) : apps
            AppState.shared.applications = finalApps
            AppState.shared.selectedAppIndex = finalApps.count > 1 ? 1 : 0
            AppState.shared.selectedWindowIndex = 0
            AppState.shared.isVisible = true
        }

        // Get the intrinsic size from SwiftUI content
        let fittingSize = hostingView?.fittingSize ?? calculateCurrentSize()

        // Apply screen bounds
        let maxWidth: CGFloat = min(screen.frame.width * 0.9, 900)
        let maxHeight: CGFloat = min(screen.frame.height * 0.85, 800)
        let panelSize = CGSize(
            width: min(fittingSize.width, maxWidth),
            height: min(fittingSize.height, maxHeight)
        )

        // Center on screen, slightly above center for aesthetic
        let origin = CGPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.frame.midY - panelSize.height / 2 + 40
        )
        setFrame(CGRect(origin: origin, size: panelSize), display: true)

        // Store the top of the grid as anchor point
        gridTopY = origin.y + panelSize.height

        // Show instantly
        alphaValue = 1
        if makeKey {
            makeKeyAndOrderFront(nil)
        } else {
            // Mirror panel: show it without stealing key status from the primary panel.
            orderFrontRegardless()
        }

        // Start monitoring for clicks outside (posts notification for manager to handle)
        startClickOutsideMonitor()
    }

    /// Deterministically focus this panel's search text field.
    /// Unlike walking `NSApp.keyWindow`, this targets THIS panel specifically, so with
    /// multiple mirror panels the search focus lands on the intended screen.
    func focusSearchField() {
        guard let textField = Self.findEditableTextField(in: contentView) else { return }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(textField)
    }

    /// Find the first editable NSTextField in a view hierarchy.
    private static func findEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view = view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable {
            return tf
        }
        for subview in view.subviews {
            if let found = findEditableTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    /// Recenter on the associated screen (called when screen configuration changes)
    func recenterOnAssociatedScreen() {
        recenterIfVisible()
    }

    /// Hide the panel without resetting AppState (used by manager)
    func hidePanel() {
        stopClickOutsideMonitor()
        alphaValue = 0
        orderOut(nil)
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
        // Posts notification so SwitcherPanelManager can check ALL panels before dismissing
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isVisible else { return }

            let screenLocation = NSEvent.mouseLocation

            // Post notification with click location - manager will check all panels
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .clickOutsideDetected,
                    object: nil,
                    userInfo: ["location": screenLocation]
                )
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
