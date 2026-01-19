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

        // Capture existing order for MRU preservation
        let existingOrder = cache.map { $0.pid }

        // Enumerate synchronously (this is slow, ~100-200ms)
        let freshApplications = enumerator.enumerateGroupedByApp()

        // Merge preserving MRU order
        if existingOrder.isEmpty {
            cache = freshApplications
        } else {
            var freshByPid: [pid_t: ApplicationModel] = [:]
            for app in freshApplications {
                freshByPid[app.pid] = app
            }

            var result: [ApplicationModel] = []
            var usedPids: Set<pid_t> = []

            for pid in existingOrder {
                if let freshApp = freshByPid[pid] {
                    result.append(freshApp)
                    usedPids.insert(pid)
                }
            }

            for app in freshApplications {
                if !usedPids.contains(app.pid) {
                    result.append(app)
                }
            }

            cache = result
        }

        lastUpdate = Date()
        return cache
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

        // Capture existing order BEFORE releasing lock
        let existingOrder = cache.map { $0.pid }
        lock.unlock()

        // Run enumeration (this is the slow part - don't hold lock during this!)
        let freshApplications = enumerator.enumerateGroupedByApp()

        // Merge: preserve MRU order from existing cache, but use fresh window data
        let mergedApplications: [ApplicationModel]
        if existingOrder.isEmpty {
            // No existing order - use fresh data as-is
            mergedApplications = freshApplications
        } else {
            // Build a lookup of fresh apps by PID
            var freshByPid: [pid_t: ApplicationModel] = [:]
            for app in freshApplications {
                freshByPid[app.pid] = app
            }

            // Start with apps in existing order (that still exist)
            var result: [ApplicationModel] = []
            var usedPids: Set<pid_t> = []

            for pid in existingOrder {
                if let freshApp = freshByPid[pid] {
                    result.append(freshApp)
                    usedPids.insert(pid)
                }
            }

            // Add any new apps that weren't in old cache (at the end)
            for app in freshApplications {
                if !usedPids.contains(app.pid) {
                    result.append(app)
                }
            }

            mergedApplications = result
        }

        // Update cache atomically
        lock.lock()
        cache = mergedApplications
        lastUpdate = Date()
        prefetchInProgress = false
        lock.unlock()

        print("[WindowCache] Prefetch complete, \(mergedApplications.count) apps, preserved MRU order")
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
            // App not in cache - invalidate so next fetch gets fresh data
            print("[WindowCache] moveAppToFront: app PID \(pid) not in cache, invalidating")
            lastUpdate = nil
            return
        }

        let appName = cache[index].name

        // Already at front? Just update active state
        if index == 0 {
            print("[WindowCache] moveAppToFront: \(appName) already at front")
            if !cache.isEmpty && !cache[0].isActive {
                cache[0] = ApplicationModel(
                    pid: cache[0].pid,
                    bundleIdentifier: cache[0].bundleIdentifier,
                    name: cache[0].name,
                    icon: cache[0].icon,
                    windows: cache[0].windows,
                    isActive: true
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
                isActive: i == 0
            )
        }

        // Log the new order (top 5 apps)
        let topApps = cache.prefix(5).map { $0.name }.joined(separator: " > ")
        print("[WindowCache] moveAppToFront: \(appName) moved from index \(index) to front. Order: \(topApps)")
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
                print("[WindowCache] Ignoring our own activation: \(app.localizedName ?? "unknown")")
                return
            }

            // When an app is activated externally, move it to front of our cache
            self.moveAppToFront(pid: pid, fromOurSwitch: false)
            print("[WindowCache] App activated externally: \(app.localizedName ?? "unknown")")
        }
        workspaceObservers.append(activateObserver)

        // These events require cache invalidation (app list changed)
        let invalidatingNotifications: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]

        for name in invalidatingNotifications {
            let observer = notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.invalidate()
            }
            workspaceObservers.append(observer)
        }

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
