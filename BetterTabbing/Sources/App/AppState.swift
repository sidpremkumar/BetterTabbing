import SwiftUI
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
    /// The grid uses adaptive columns ~92px wide (80-100 min/max + spacing)
    /// For a ~660px content width, that's approximately 7 items per row
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
        // If already on first row, don't wrap - stay in place
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
            // If going past the last row, go to the last item
            let lastIndex = count - 1
            if selectedAppIndex != lastIndex {
                selectedAppIndex = lastIndex
                selectedWindowIndex = 0
            }
        }
    }

    /// Calculate approximate items per row based on dynamic panel width
    /// Grid uses .adaptive(minimum: 76, maximum: 90) with 6px spacing
    /// Tile is ~76px with 6px padding = ~82px per item
    private func calculateItemsPerRow() -> Int {
        // Calculate based on app count (matching SwitcherView.calculateWidth())
        let appCount = filteredApplications.count
        let itemWidth: CGFloat = 82  // ~76-90 tile + 6 spacing

        // Width calculation matches SwitcherView
        let idealItemsPerRow = min(appCount, 8)
        let baseWidth = CGFloat(idealItemsPerRow) * 92 + 32
        let contentWidth = min(max(baseWidth, 400), 750) - 32  // Subtract padding

        return max(1, Int(contentWidth / itemWidth))
    }

    func reset() {
        isVisible = false
        selectedAppIndex = 0
        selectedWindowIndex = 0
        selectedSearchIndex = 0
        isSearchActive = false
        searchQuery = ""
        isKeyboardNavigating = false
        hasMouseMoved = false
        lastMousePosition = nil
    }

    private init() {}
}
