import Foundation
import AppKit
import Combine

/// High-performance window cache with lock-free reads for maximum speed
final class WindowCache: @unchecked Sendable {
    static let shared = WindowCache()

    // Use atomic pointer swap for lock-free reads
    private var cache: [ApplicationModel] = []
    private var lastUpdate: Date?
    private let ttl: TimeInterval = 2.0  // 2 second cache - longer TTL since we refresh on activation
    private let lock = NSLock()

    // Track if a prefetch is in progress to avoid duplicate work
    private var prefetchInProgress = false

    // Suppress external activation notifications during our own switches
    // Only suppress the specific app we just switched to
    private var suppressedPid: pid_t?
    private var suppressUntil: Date?

    // An activation that arrived while its app wasn't in the cache yet (freshly launched or
    // relaunched app). Dropping it silently leaves the frontmost app stranded at the END of
    // the MRU list; instead we remember it and promote the app once a refresh brings it in.
    private var pendingFrontPid: pid_t?
    private var pendingFrontSetAt: Date?

    private let enumerator = WindowEnumerator()
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    /// Get cached applications WITHOUT blocking - returns stale data if cache is being refreshed
    /// This is the fast path for UI display
    func getCachedApplications() -> [ApplicationModel] {
        // Lock-free read of cached data
        return cache
    }

    /// Check if we have any cached data
    var hasCachedData: Bool {
        return !cache.isEmpty
    }

    /// Get applications - uses cache if valid, otherwise enumerates synchronously
    /// WARNING: This can block if called while prefetch is running
    func getApplicationsSync(forceRefresh: Bool = false) -> [ApplicationModel] {
        lock.lock()
        defer { lock.unlock() }

        if !forceRefresh,
           let lastUpdate = lastUpdate,
           Date().timeIntervalSince(lastUpdate) < ttl,
           !cache.isEmpty {
            return cache
        }

        // Enumerate synchronously (this is slow, ~100-200ms)
        var freshApplications = enumerator.enumerateGroupedByApp()
        attachResourceUsage(to: &freshApplications)

        cache = applyPendingFront(to: mergeIntoCache(freshApplications))
        lastUpdate = Date()
        return cache
    }

    /// Merge freshly-enumerated apps into the existing MRU-ordered cache.
    /// Preserves the current cache order for apps still present, and — crucially — keeps apps
    /// that are still running but were transiently absent from THIS enumeration pass (AX can
    /// flake under heavy switching). Without this, a missed app gets evicted and later re-added
    /// as a "new" app in alphabetical order, i.e. dumped at the end of the list. Genuinely
    /// terminated apps (process gone) are dropped; brand-new apps are appended after the order.
    /// Caller MUST hold `lock`.
    private func mergeIntoCache(_ fresh: [ApplicationModel]) -> [ApplicationModel] {
        let currentCache = cache
        if currentCache.isEmpty {
            return fresh
        }

        var freshByPid: [pid_t: ApplicationModel] = [:]
        for app in fresh { freshByPid[app.pid] = app }

        let runningPids = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })

        var result: [ApplicationModel] = []
        var usedPids: Set<pid_t> = []

        for existing in currentCache {
            let pid = existing.pid
            if let freshApp = freshByPid[pid] {
                // Present this pass — use fresh window/resource data.
                result.append(freshApp)
                usedPids.insert(pid)
            } else if WindowEnumerator.hideWhenNoWindowsBundleIDs.contains(existing.bundleIdentifier) {
                // Always-running app (Finder) that was intentionally left out because it has no
                // windows anymore — drop it rather than keeping a stale entry around.
                DiagnosticLog.shared.log("[WindowCache] merge: \(existing.name) (pid \(pid)) has no windows — dropped from cache")
            } else if runningPids.contains(pid) {
                // Still running but missed this enumeration — keep in place, do NOT evict.
                result.append(existing)
                usedPids.insert(pid)
                DiagnosticLog.shared.log("[WindowCache] merge: \(existing.name) (pid \(pid)) missing from enumeration but still running — kept in place")
            } else {
                DiagnosticLog.shared.log("[WindowCache] merge: \(existing.name) (pid \(pid)) process gone — dropped from cache")
            }
        }

        // Brand-new apps that weren't in the cache yet (appended after the preserved order).
        for app in fresh where !usedPids.contains(app.pid) {
            result.append(app)
            DiagnosticLog.shared.log("[WindowCache] merge: \(app.name) (pid \(app.pid)) not in cache — appended at END (index \(result.count - 1))")
        }

        return result
    }

    /// Promote the app whose activation arrived before it was cached (see pendingFrontPid).
    /// A pending pid survives refreshes that still miss the app (its windows may not exist
    /// yet right after launch), capped at 10s so a stale marker can't promote much later.
    /// Caller MUST hold `lock`.
    private func applyPendingFront(to apps: [ApplicationModel]) -> [ApplicationModel] {
        guard let pid = pendingFrontPid else { return apps }

        if let index = apps.firstIndex(where: { $0.pid == pid }) {
            pendingFrontPid = nil
            pendingFrontSetAt = nil
            var result = apps
            let app = result.remove(at: index)
            result.insert(app, at: 0)
            DiagnosticLog.shared.log("[WindowCache] applyPendingFront: \(app.name) (pid \(pid)) promoted from index \(index) to front after refresh")
            return result
        }

        if let setAt = pendingFrontSetAt, Date().timeIntervalSince(setAt) > 10 {
            DiagnosticLog.shared.log("[WindowCache] applyPendingFront: pid \(pid) never appeared in a refresh, discarding pending activation")
            pendingFrontPid = nil
            pendingFrontSetAt = nil
        }
        return apps
    }

    /// Async wrapper for compatibility
    func getApplications(forceRefresh: Bool = false) async -> [ApplicationModel] {
        return getApplicationsSync(forceRefresh: forceRefresh)
    }

    /// Pre-fetch window data - runs enumeration and updates cache
    /// Call this early so data is ready when needed
    /// IMPORTANT: This preserves MRU order from existing cache
    func prefetch() {
        // Don't start another prefetch if one is already running
        lock.lock()
        if prefetchInProgress {
            lock.unlock()
            return
        }
        prefetchInProgress = true
        lock.unlock()

        // Run enumeration (this is the slow part - don't hold lock during this!)
        var freshApplications = enumerator.enumerateGroupedByApp()
        attachResourceUsage(to: &freshApplications)

        // Merge under the lock, using the CURRENT cache order as the authority.
        // This captures any moveAppToFront() that happened during enumeration, so a
        // quick-switch that raced with this prefetch is not clobbered by a stale snapshot.
        // mergeIntoCache also preserves still-running apps missed by this enumeration pass.
        lock.lock()
        var result = applyPendingFront(to: mergeIntoCache(freshApplications))

        // Keep isActive consistent with MRU convention (front = active), so the fresh
        // enumeration's stale active flag doesn't fight moveAppToFront after a race.
        for i in result.indices where result[i].isActive != (i == 0) {
            result[i] = ApplicationModel(
                pid: result[i].pid,
                bundleIdentifier: result[i].bundleIdentifier,
                name: result[i].name,
                icon: result[i].icon,
                windows: result[i].windows,
                isActive: i == 0,
                memoryBytes: result[i].memoryBytes
            )
        }

        cache = result
        lastUpdate = Date()
        prefetchInProgress = false
        let order = result.prefix(10).map { $0.name }.joined(separator: " > ")
        lock.unlock()

        DiagnosticLog.shared.log("[WindowCache] Prefetch complete, \(result.count) apps. Order: \(order)")
    }

    /// Prefetch on background thread - non-blocking
    func prefetchAsync() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.prefetch()
        }
    }

    func invalidate() {
        lock.lock()
        lastUpdate = nil
        lock.unlock()
    }

    /// Move an app to the front of the cache (called after switching to it)
    /// This is much faster than re-enumerating all windows
    /// Set fromOurSwitch=true when called from WindowSwitcher to suppress duplicate notifications
    func moveAppToFront(pid: pid_t, fromOurSwitch: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        // If this is from our own switch, suppress external notifications for this specific app briefly
        if fromOurSwitch {
            suppressedPid = pid
            suppressUntil = Date().addingTimeInterval(0.3)  // 300ms window (shorter to allow rapid switching)
        }

        guard let index = cache.firstIndex(where: { $0.pid == pid }) else {
            // App not in cache (freshly launched/relaunched). Don't drop the activation:
            // remember it so the next refresh promotes this app to the front instead of
            // leaving it stranded at the end of the MRU list.
            DiagnosticLog.shared.log("[WindowCache] moveAppToFront: app PID \(pid) not in cache, deferring to next refresh")
            pendingFrontPid = pid
            pendingFrontSetAt = Date()
            lastUpdate = nil
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.prefetch()
            }
            return
        }

        // This activation supersedes any deferred one for a not-yet-cached app.
        pendingFrontPid = nil

        let appName = cache[index].name

        // Already at front? Just update active state
        if index == 0 {
            DiagnosticLog.shared.log("[WindowCache] moveAppToFront: \(appName) already at front (fromOurSwitch: \(fromOurSwitch))")
            if !cache.isEmpty && !cache[0].isActive {
                cache[0] = ApplicationModel(
                    pid: cache[0].pid,
                    bundleIdentifier: cache[0].bundleIdentifier,
                    name: cache[0].name,
                    icon: cache[0].icon,
                    windows: cache[0].windows,
                    isActive: true,
                    memoryBytes: cache[0].memoryBytes
                )
            }
            return
        }

        // Move the activated app to the front
        let app = cache.remove(at: index)
        cache.insert(app, at: 0)

        // Mark the app as active, others as not active
        for i in cache.indices {
            cache[i] = ApplicationModel(
                pid: cache[i].pid,
                bundleIdentifier: cache[i].bundleIdentifier,
                name: cache[i].name,
                icon: cache[i].icon,
                windows: cache[i].windows,
                isActive: i == 0,
                memoryBytes: cache[i].memoryBytes
            )
        }

        // Log the new order (top 10 apps)
        let topApps = cache.prefix(10).map { $0.name }.joined(separator: " > ")
        DiagnosticLog.shared.log("[WindowCache] moveAppToFront: \(appName) moved from index \(index) to front (fromOurSwitch: \(fromOurSwitch)). Order: \(topApps)")
    }

    /// Check if external activation should be suppressed for a specific PID
    private func shouldSuppressExternalActivation(for pid: pid_t) -> Bool {
        if let suppressedPid = suppressedPid, suppressedPid == pid {
            if let until = suppressUntil, Date() < until {
                return true
            }
            // Suppression expired
            self.suppressedPid = nil
            suppressUntil = nil
        }
        return false
    }

    /// Attach resource usage data to applications (lightweight, ~1-3ms)
    private func attachResourceUsage(to apps: inout [ApplicationModel]) {
        let pids = apps.map { $0.pid }
        let snapshot = ProcessResourceMonitor.shared.snapshot(pids: pids)
        for i in apps.indices {
            if let usage = snapshot[apps[i].pid] {
                apps[i].memoryBytes = usage.memoryBytes
            }
        }
    }

    func startMonitoring() {
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter

        // Track app activations to maintain correct MRU order
        let activateObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

            let pid = app.processIdentifier

            // Skip if we're suppressing this specific app (our own switch just happened)
            if self.shouldSuppressExternalActivation(for: pid) {
                DiagnosticLog.shared.log("[WindowCache] Ignoring our own activation: \(app.localizedName ?? "unknown")")
                return
            }

            // When an app is activated externally, move it to front of our cache
            DiagnosticLog.shared.log("[WindowCache] App activated externally: \(app.localizedName ?? "unknown") (pid \(pid))")
            self.moveAppToFront(pid: pid, fromOurSwitch: false)
        }
        workspaceObservers.append(activateObserver)

        // App launch/terminate require immediate cache refresh (not just invalidation)
        let refreshNotifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]

        for name in refreshNotifications {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self = self else { return }
                let appName = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "unknown"
                DiagnosticLog.shared.log("[WindowCache] App \(name == NSWorkspace.didLaunchApplicationNotification ? "launched" : "terminated"): \(appName), refreshing cache")
                self.invalidate()
                self.prefetchAsync()
            }
            workspaceObservers.append(observer)
        }

        // Space change just needs invalidation (will refresh on next access)
        let spaceObserver = notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidate()
        }
        workspaceObservers.append(spaceObserver)

        print("[WindowCache] Started monitoring workspace notifications")
    }

    func stopMonitoring() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            notificationCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()
        print("[WindowCache] Stopped monitoring workspace notifications")
    }
}
