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
        let applications = enumerator.enumerateGroupedByApp()
        cache = applications
        lastUpdate = Date()

        return applications
    }

    /// Async wrapper for compatibility
    func getApplications(forceRefresh: Bool = false) async -> [ApplicationModel] {
        return getApplicationsSync(forceRefresh: forceRefresh)
    }

    /// Pre-fetch window data - runs enumeration and updates cache
    /// Call this early so data is ready when needed
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
        let applications = enumerator.enumerateGroupedByApp()

        // Update cache atomically
        lock.lock()
        cache = applications
        lastUpdate = Date()
        prefetchInProgress = false
        lock.unlock()
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
    func moveAppToFront(pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }

        guard let index = cache.firstIndex(where: { $0.pid == pid }) else {
            // App not in cache - invalidate so next fetch gets fresh data
            lastUpdate = nil
            return
        }

        // Already at front? Just update active state
        if index == 0 {
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
            // When an app is activated (by any means), move it to front of our cache
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.moveAppToFront(pid: app.processIdentifier)
                print("[WindowCache] App activated externally: \(app.localizedName ?? "unknown")")
            }
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
