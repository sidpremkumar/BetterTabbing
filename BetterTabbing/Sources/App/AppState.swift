import SwiftUI
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // MARK: - Switcher State

    @Published var isVisible = false
    @Published var applications: [ApplicationModel] = []
    @Published var selectedAppIndex = 0
    @Published var selectedWindowIndex = 0
    @Published var isSearchActive = false
    @Published var searchQuery = ""
    @Published var selectedSearchIndex = 0  // Index into search results
    @Published var isKeyboardNavigating = false  // When true, ignore mouse hover
    @Published var hasMouseMoved = false  // Whether mouse has actually moved since panel appeared
    var lastMousePosition: CGPoint? = nil  // Track last mouse position to detect actual movement

    // MARK: - Resource Monitor State

    @Published var isResourceMonitorActive = false
    @Published var isProcessGroupingEnabled = true
    @Published var resourceEntries: [ProcessResourceMonitor.ProcessResourceEntry] = []
    @Published var systemMemory: ProcessResourceMonitor.SystemMemory?
    @Published var systemCPU: ProcessResourceMonitor.SystemCPU?
    @Published var cpuTemperature: Double?
    @Published var thermalState: ProcessInfo.ThermalState = .nominal

    /// History of system CPU usage for the live graph (most recent last)
    @Published var cpuHistory: [Double] = []
    /// History of system memory usage fraction for the live graph
    @Published var memoryHistory: [Double] = []

    // MARK: - AI Insight State

    @Published var aiInsight: String?
    @Published var aiInsightLoading = false
    /// Whether Ollama is reachable (checked once per monitor open)
    @Published var ollamaAvailable = false
    /// Prevents re-querying every poll — only once per monitor session
    private var hasRequestedInsight = false
    /// Timer that clears the AI insight after it becomes stale
    private var aiInsightCooldownTimer: Timer?
    /// Seconds before the AI insight auto-clears (processes change, old summary is irrelevant)
    private let aiInsightCooldown: TimeInterval = 30

    /// Maximum number of history points to keep (at 1s intervals = 60s of data)
    private let maxHistoryPoints = 60

    private var resourceTimer: Timer?

    // MARK: - E Hold (Charging Animation) State

    @Published var isEHoldActive = false
    @Published var eHoldProgress: CGFloat = 0.0
    private var eHoldTimer: Timer?
    private var eHoldStartTime: Date?
    /// Duration for the charging bar to fill (visual only — actual threshold is in KeyboardEventTap)
    private let eHoldAnimationDuration: TimeInterval = 0.5

    // MARK: - Quit Hold State

    @Published var isQuitHoldActive = false
    @Published var quitHoldProgress: CGFloat = 0.0
    @Published var quitTargetAppIndex: Int? = nil
    private var quitHoldTimer: Timer?
    private var quitHoldStartTime: Date?
    private var quitHoldDuration: TimeInterval { TimeInterval(preferences.quitHoldDuration) }

    // MARK: - Preferences

    @Published var preferences = UserPreferences.load() {
        didSet {
            preferences.save()
        }
    }

    // MARK: - Computed Properties

    /// Search results when searching - includes both apps and specific windows
    var searchResults: [SearchResult] {
        return FuzzyMatcher.search(applications, query: searchQuery)
    }

    /// Selected search result
    var selectedSearchResult: SearchResult? {
        guard searchResults.indices.contains(selectedSearchIndex) else { return nil }
        return searchResults[selectedSearchIndex]
    }

    var selectedApp: ApplicationModel? {
        // When actively searching with a query, use search results
        if isSearchActive && !searchQuery.isEmpty {
            return selectedSearchResult?.app
        }
        // Otherwise use the app grid
        guard filteredApplications.indices.contains(selectedAppIndex) else { return nil }
        return filteredApplications[selectedAppIndex]
    }

    var filteredApplications: [ApplicationModel] {
        guard !searchQuery.isEmpty else { return applications }
        return FuzzyMatcher.filter(applications, query: searchQuery)
    }

    // MARK: - Navigation Methods

    /// Call this when keyboard navigation is used
    func markKeyboardNavigation() {
        isKeyboardNavigating = true
    }

    /// Call this when mouse moves to re-enable hover
    /// Only marks mouse navigation if the mouse has actually moved from its last position
    func markMouseNavigation(at position: CGPoint? = nil) {
        // If position provided, check if mouse actually moved
        if let position = position {
            if let lastPos = lastMousePosition {
                // Only consider it a move if position changed by more than 2 pixels
                let dx = abs(position.x - lastPos.x)
                let dy = abs(position.y - lastPos.y)
                if dx > 2 || dy > 2 {
                    hasMouseMoved = true
                    isKeyboardNavigating = false
                    lastMousePosition = position
                }
            } else {
                // First position recorded, don't count as movement yet
                lastMousePosition = position
            }
        } else {
            // No position provided, only enable if mouse has already moved
            if hasMouseMoved {
                isKeyboardNavigating = false
            }
        }
    }

    /// Check if mouse input should be processed (mouse has moved since panel appeared)
    var shouldProcessMouseInput: Bool {
        return hasMouseMoved && !isKeyboardNavigating
    }

    func selectNextApp() {
        markKeyboardNavigation()
        if isSearchActive && !searchQuery.isEmpty {
            // Navigate through search results
            let count = searchResults.count
            guard count > 0 else { return }
            selectedSearchIndex = (selectedSearchIndex + 1) % count
            // Update window index if search result targets a specific window
            if let result = selectedSearchResult, let windowIndex = result.targetWindowIndex {
                selectedWindowIndex = windowIndex
            }
        } else {
            let count = filteredApplications.count
            guard count > 0 else { return }
            selectedAppIndex = (selectedAppIndex + 1) % count
            selectedWindowIndex = 0
        }
    }

    func selectPreviousApp() {
        markKeyboardNavigation()
        if isSearchActive && !searchQuery.isEmpty {
            // Navigate through search results
            let count = searchResults.count
            guard count > 0 else { return }
            selectedSearchIndex = (selectedSearchIndex - 1 + count) % count
            // Update window index if search result targets a specific window
            if let result = selectedSearchResult, let windowIndex = result.targetWindowIndex {
                selectedWindowIndex = windowIndex
            }
        } else {
            let count = filteredApplications.count
            guard count > 0 else { return }
            selectedAppIndex = (selectedAppIndex - 1 + count) % count
            selectedWindowIndex = 0
        }
    }

    func selectNextWindow() {
        markKeyboardNavigation()
        guard let app = selectedApp else { return }
        let count = app.windows.count
        guard count > 0 else { return }
        selectedWindowIndex = (selectedWindowIndex + 1) % count
    }

    func selectPreviousWindow() {
        markKeyboardNavigation()
        guard let app = selectedApp else { return }
        let count = app.windows.count
        guard count > 0 else { return }
        selectedWindowIndex = (selectedWindowIndex - 1 + count) % count
    }

    /// Move selection to the row above in the grid
    func selectAppInRowAbove() {
        markKeyboardNavigation()
        let count = filteredApplications.count
        guard count > 0 else { return }

        let itemsPerRow = calculateItemsPerRow()
        let newIndex = selectedAppIndex - itemsPerRow

        if newIndex >= 0 {
            selectedAppIndex = newIndex
            selectedWindowIndex = 0
        }
    }

    /// Move selection to the row below in the grid
    func selectAppInRowBelow() {
        markKeyboardNavigation()
        let count = filteredApplications.count
        guard count > 0 else { return }

        let itemsPerRow = calculateItemsPerRow()
        let newIndex = selectedAppIndex + itemsPerRow

        if newIndex < count {
            selectedAppIndex = newIndex
            selectedWindowIndex = 0
        } else {
            let lastIndex = count - 1
            if selectedAppIndex != lastIndex {
                selectedAppIndex = lastIndex
                selectedWindowIndex = 0
            }
        }
    }

    private func calculateItemsPerRow() -> Int {
        let appCount = filteredApplications.count
        let itemWidth: CGFloat = 82

        let idealItemsPerRow = min(appCount, 8)
        let baseWidth = CGFloat(idealItemsPerRow) * 92 + 32
        let contentWidth = min(max(baseWidth, 400), 750) - 32

        return max(1, Int(contentWidth / itemWidth))
    }

    // MARK: - Resource Monitor Methods

    func toggleResourceMonitor() {
        isResourceMonitorActive.toggle()
        if isResourceMonitorActive {
            startResourcePolling()
        } else {
            stopResourcePolling()
        }
    }

    private func startResourcePolling() {
        // Prime the CPU delta sampler (need fresh baseline for accurate %)
        ProcessResourceMonitor.shared.resetSamples()
        // Keep cpuHistory/memoryHistory across toggles so the graph persists
        hasRequestedInsight = false

        // Quick reachability check (non-blocking, 2s timeout)
        // Used to show the right hint text — hold-E will start Ollama regardless
        Task {
            let available = await OllamaClient.shared.isAvailable()
            await MainActor.run { self.ollamaAvailable = available }
        }

        // Initial "priming" fetch — CPU% will be 0 on first call (no delta yet)
        refreshResourceData()

        // Poll every 1.5 seconds for smooth updates
        resourceTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshResourceData()
            }
        }
    }

    private func stopResourcePolling() {
        resourceTimer?.invalidate()
        resourceTimer = nil
        resourceEntries = []
        systemMemory = nil
        systemCPU = nil
        cpuTemperature = nil
        // Intentionally keep cpuHistory & memoryHistory — 960 bytes in RAM,
        // lets the graph show prior context when reopened.
        aiInsightCooldownTimer?.invalidate()
        aiInsightCooldownTimer = nil
        hasRequestedInsight = false
        ProcessResourceMonitor.shared.resetSamples()

        // Kill Ollama if we started it — don't leave it running
        Task { await OllamaClient.shared.shutdownIfWeStarted() }
    }

    private func refreshResourceData() {
        let monitor = ProcessResourceMonitor.shared
        resourceEntries = monitor.systemSnapshot()
        systemMemory = monitor.systemMemory()
        systemCPU = monitor.systemCPU()

        // Temperature: exact °C on Intel, thermal state fallback on Apple Silicon
        let thermal = monitor.thermalInfo()
        cpuTemperature = thermal.temperature
        thermalState = thermal.state

        // Append to history
        if let cpu = systemCPU {
            cpuHistory.append(cpu.usagePercent)
            if cpuHistory.count > maxHistoryPoints {
                cpuHistory.removeFirst(cpuHistory.count - maxHistoryPoints)
            }
        }
        if let mem = systemMemory {
            memoryHistory.append(mem.usedFraction * 100)
            if memoryHistory.count > maxHistoryPoints {
                memoryHistory.removeFirst(memoryHistory.count - maxHistoryPoints)
            }
        }

    }

    // MARK: - AI Insight (Hold E)

    /// Called when user holds E — starts Ollama if needed, queries, then shuts down.
    func requestAIInsightWithOllama() {
        guard !aiInsightLoading else { return }

        // Ensure resource monitor is showing
        if !isResourceMonitorActive {
            isResourceMonitorActive = true
            startResourcePolling()
        }

        aiInsightLoading = true

        Task {
            // Start Ollama if not running (will track if we started it)
            let ready = await OllamaClient.shared.ensureRunning()
            await MainActor.run { self.ollamaAvailable = ready }

            guard ready else {
                await MainActor.run {
                    self.aiInsightLoading = false
                    self.aiInsight = "Could not start Ollama. Install from ollama.com"
                }
                return
            }

            // Wait for at least 2 data points if we don't have them yet
            for _ in 0..<6 {
                let count = await MainActor.run { self.cpuHistory.count }
                if count >= 2 { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            let snapshot = await MainActor.run { self.buildSnapshot() }
            let result = await OllamaClient.shared.summarizeProcesses(snapshot)

            await MainActor.run {
                self.setAIInsight(result ?? "No response from model")
                self.aiInsightLoading = false
            }
        }
    }

    /// Manually refresh the AI insight (e.g. user taps refresh button)
    func refreshAIInsight() {
        guard ollamaAvailable, !aiInsightLoading else { return }
        aiInsightLoading = true
        let snapshot = buildSnapshot()
        Task {
            let result = await OllamaClient.shared.summarizeProcesses(snapshot)
            await MainActor.run {
                self.setAIInsight(result)
                self.aiInsightLoading = false
            }
        }
    }

    /// Set the AI insight and start the cooldown timer to auto-clear it
    private func setAIInsight(_ text: String?) {
        aiInsightCooldownTimer?.invalidate()
        aiInsight = text

        guard text != nil else { return }
        aiInsightCooldownTimer = Timer.scheduledTimer(withTimeInterval: aiInsightCooldown, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.aiInsight = nil
            }
        }
    }

    private func buildSnapshot() -> ProcessSnapshot {
        ProcessSnapshot(
            processes: resourceEntries.prefix(8).map { entry in
                ProcessSnapshot.Process(
                    name: entry.name,
                    cpuPercent: entry.cpuPercent,
                    memMB: Int(entry.memoryBytes / (1024 * 1024))
                )
            },
            cpuUsagePercent: Int(systemCPU?.usagePercent ?? 0),
            memUsedGB: systemMemory?.formattedUsed ?? "?",
            memTotalGB: systemMemory?.formattedTotal ?? "?",
            tempC: cpuTemperature
        )
    }

    // MARK: - E Hold Methods (Charging Animation)

    func startEHold() {
        guard !isEHoldActive else { return }
        isEHoldActive = true
        eHoldProgress = 0.0
        eHoldStartTime = Date()

        eHoldTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateEHoldProgress()
            }
        }
    }

    func cancelEHold(triggeredAI: Bool) {
        eHoldTimer?.invalidate()
        eHoldTimer = nil
        eHoldStartTime = nil

        if triggeredAI {
            // Keep progress full briefly to show completion
            eHoldProgress = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isEHoldActive = false
                self?.eHoldProgress = 0.0
            }
        } else {
            isEHoldActive = false
            eHoldProgress = 0.0
        }
    }

    private func updateEHoldProgress() {
        guard let start = eHoldStartTime else { return }
        let elapsed = Date().timeIntervalSince(start)
        eHoldProgress = min(CGFloat(elapsed / eHoldAnimationDuration), 1.0)
    }

    // MARK: - Quit Hold Methods

    func startQuitHold() {
        guard selectedApp != nil else { return }
        isQuitHoldActive = true
        quitHoldProgress = 0.0
        quitTargetAppIndex = selectedAppIndex
        quitHoldStartTime = Date()

        quitHoldTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateQuitHoldProgress()
            }
        }
    }

    func cancelQuitHold() {
        quitHoldTimer?.invalidate()
        quitHoldTimer = nil
        quitHoldStartTime = nil
        isQuitHoldActive = false
        quitHoldProgress = 0.0
        quitTargetAppIndex = nil
    }

    private func updateQuitHoldProgress() {
        guard let startTime = quitHoldStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let fraction = min(elapsed / quitHoldDuration, 1.0)
        quitHoldProgress = CGFloat(fraction)

        if fraction >= 1.0 {
            executeQuit()
        }
    }

    private func executeQuit() {
        quitHoldTimer?.invalidate()
        quitHoldTimer = nil

        guard let app = selectedApp else {
            cancelQuitHold()
            return
        }

        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first {
            runningApp.terminate()
            print("[AppState] Quit app: \(app.name)")
        }

        if let index = applications.firstIndex(where: { $0.pid == app.pid }) {
            applications.remove(at: index)
            if selectedAppIndex >= applications.count {
                selectedAppIndex = max(0, applications.count - 1)
            }
        }

        isQuitHoldActive = false
        quitHoldProgress = 0.0
        quitTargetAppIndex = nil
        quitHoldStartTime = nil
    }

    func reset() {
        cancelEHold(triggeredAI: false)
        cancelQuitHold()
        stopResourcePolling()
        isVisible = false
        selectedAppIndex = 0
        selectedWindowIndex = 0
        selectedSearchIndex = 0
        isSearchActive = false
        searchQuery = ""
        isKeyboardNavigating = false
        hasMouseMoved = false
        lastMousePosition = nil
        isResourceMonitorActive = false
    }

    private init() {}
}
