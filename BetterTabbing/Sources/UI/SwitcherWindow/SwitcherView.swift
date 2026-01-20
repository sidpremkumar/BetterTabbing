import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
    @Namespace private var selectionNamespace
    @FocusState private var isSearchFocused: Bool

    /// Whether to show search results list (when searching with query)
    private var showSearchResults: Bool {
        appState.isSearchActive && !appState.searchQuery.isEmpty
    }

    /// Whether selected app has multiple windows to show
    private var showWindowList: Bool {
        guard let selectedApp = appState.selectedApp else { return false }
        return selectedApp.hasMultipleWindows && !showSearchResults
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar - slides in from top when active
            if appState.isSearchActive {
                SearchBarView(
                    searchQuery: $appState.searchQuery,
                    isFocused: $isSearchFocused,
                    onSubmit: {
                        confirmSelection()
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
                .transition(.opacity.animation(.easeOut(duration: 0.15)))
            }

            if showSearchResults {
                // Search results list
                SearchResultsListView(
                    results: appState.searchResults,
                    selectedIndex: appState.selectedSearchIndex,
                    onResultClicked: { index in
                        appState.selectedSearchIndex = index
                        if let result = appState.selectedSearchResult,
                           let windowIndex = result.targetWindowIndex {
                            appState.selectedWindowIndex = windowIndex
                        }
                        confirmSelection()
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 14)

            } else {
                // App grid (normal mode) - explicitly disable animation on grid content
                AppGridView(
                    applications: appState.filteredApplications,
                    selectedIndex: appState.selectedAppIndex,
                    namespace: selectionNamespace,
                    onAppClicked: { index in
                        appState.selectedAppIndex = index
                        appState.selectedWindowIndex = 0
                        confirmSelection()
                    },
                    onAppHovered: { index in
                        guard appState.shouldProcessMouseInput else { return }
                        appState.selectedAppIndex = index
                        appState.selectedWindowIndex = 0
                    }
                )
                .onContinuousHover { phase in
                    if case .active = phase {
                        // Use screen mouse position for tracking actual movement
                        appState.markMouseNavigation(at: NSEvent.mouseLocation)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                // Keyboard hints - minimal and sleek
                keyboardHintsView
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                // Window list expands below when app has multiple windows
                if showWindowList, let selectedApp = appState.selectedApp {
                    VStack(spacing: 0) {
                        Divider()
                            .padding(.horizontal, 16)

                        WindowListView(
                            app: selectedApp,
                            selectedWindowIndex: appState.selectedWindowIndex,
                            onWindowHovered: { index in
                                guard appState.shouldProcessMouseInput else { return }
                                appState.selectedWindowIndex = index
                            },
                            onWindowClicked: { index in
                                appState.selectedWindowIndex = index
                                confirmSelection()
                            }
                        )
                        .onContinuousHover { phase in
                            if case .active = phase {
                                appState.markMouseNavigation(at: NSEvent.mouseLocation)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
        }
        .frame(width: calculateWidth())
        .fixedSize(horizontal: false, vertical: true)  // Let height be determined by content
        .background(GlassBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onChange(of: appState.isSearchActive) { oldValue, isActive in
            if isActive {
                isSearchFocused = true
                appState.selectedSearchIndex = 0
            }
        }
        .onChange(of: appState.searchQuery) { oldValue, newValue in
            appState.selectedSearchIndex = 0
        }
    }

    /// Calculate optimal width based on number of apps
    private func calculateWidth() -> CGFloat {
        let appCount = appState.filteredApplications.count

        if showSearchResults {
            return 480  // Fixed width for search results
        }

        if appState.isSearchActive && appState.searchQuery.isEmpty {
            // Search mode but no query yet - use app grid width
            let idealItemsPerRow = min(appCount, 8)
            let baseWidth = CGFloat(idealItemsPerRow) * 88 + 32
            return min(max(baseWidth, 400), 720)
        }

        // Calculate based on app count
        let idealItemsPerRow = min(appCount, 8)
        let baseWidth = CGFloat(idealItemsPerRow) * 88 + 32

        return min(max(baseWidth, 400), 720)
    }

    /// Calculate height based on content
    private func calculateHeight() -> CGFloat {
        let appCount = appState.filteredApplications.count

        // Search bar height when active
        let searchBarHeight: CGFloat = appState.isSearchActive ? 54 : 0

        if showSearchResults {
            // Search results: header + results + bottom padding
            let resultCount = min(appState.searchResults.count, 10)
            let resultsHeight = resultCount == 0 ? 80 : CGFloat(resultCount) * 44 + 24
            return searchBarHeight + resultsHeight + 14
        }

        // App grid calculation
        // Each tile: 64px icon + 6px spacing + ~14px text + 12px padding = ~96px
        // Grid spacing: 6px between rows
        let itemsPerRow = calculateItemsPerRow()
        let rows = appCount > 0 ? ceil(CGFloat(appCount) / CGFloat(itemsPerRow)) : 1
        let tileHeight: CGFloat = 96
        let gridSpacing: CGFloat = 6
        let gridHeight = rows * tileHeight + (rows - 1) * gridSpacing + 28  // +28 for vertical padding on grid

        // Keyboard hints
        let hintsHeight: CGFloat = 30

        // Window list if showing
        let windowListHeight: CGFloat = showWindowList ? 70 : 0

        return searchBarHeight + gridHeight + hintsHeight + windowListHeight
    }

    private func calculateItemsPerRow() -> Int {
        let width = calculateWidth() - 32  // Subtract padding
        let itemWidth: CGFloat = 88
        return max(1, Int(width / itemWidth))
    }

    private var keyboardHintsView: some View {
        HStack(spacing: 16) {
            KeyHint(keys: ["tab"], label: "Next")
            KeyHint(keys: ["`"], label: "Windows")
            KeyHint(keys: ["return"], label: "Search")
            KeyHint(keys: ["esc"], label: "Close")
        }
        .opacity(0.8)
    }

    private func confirmSelection() {
        NotificationCenter.default.post(name: .confirmSwitcherSelection, object: nil)
    }
}

/// A polished macOS-style keyboard key cap
struct KeyCap: View {
    let symbol: String

    /// Maps key names to SF Symbols or display text
    private var displayContent: (isSymbol: Bool, value: String) {
        switch symbol.lowercased() {
        case "tab":
            return (true, "arrow.right.to.line")
        case "return", "enter":
            return (true, "return")
        case "esc", "escape":
            return (false, "esc")
        case "shift":
            return (true, "shift")
        case "cmd", "command":
            return (true, "command")
        case "opt", "option", "alt":
            return (true, "option")
        case "ctrl", "control":
            return (true, "control")
        case "up":
            return (true, "chevron.up")
        case "down":
            return (true, "chevron.down")
        case "left":
            return (true, "chevron.left")
        case "right":
            return (true, "chevron.right")
        case "space":
            return (false, "space")
        case "`":
            return (false, "`")
        default:
            return (false, symbol.uppercased())
        }
    }

    var body: some View {
        let content = displayContent

        Group {
            if content.isSymbol {
                Image(systemName: content.value)
                    .font(.system(size: 9, weight: .medium))
            } else {
                Text(content.value)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.primary.opacity(0.6))
        .frame(minWidth: 18, minHeight: 16)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5)
                )
        )
    }
}

/// A keyboard hint showing key(s) + description
struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { key in
                    KeyCap(symbol: key)
                }
            }

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

extension Notification.Name {
    static let confirmSwitcherSelection = Notification.Name("confirmSwitcherSelection")
    static let switcherDismissedByClickOutside = Notification.Name("switcherDismissedByClickOutside")
    static let switcherConfirmedByMouseClick = Notification.Name("switcherConfirmedByMouseClick")
    static let activationModifierChanged = Notification.Name("activationModifierChanged")
    static let openPreferences = Notification.Name("openPreferences")
}
