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
    func markMouseNavigation() {
        isKeyboardNavigating = false
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

    func reset() {
        isVisible = false
        selectedAppIndex = 0
        selectedWindowIndex = 0
        selectedSearchIndex = 0
        isSearchActive = false
        searchQuery = ""
        isKeyboardNavigating = false
    }

    private init() {}
}
