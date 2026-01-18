import SwiftUI

struct SwitcherView: View {
    @EnvironmentObject var appState: AppState
    @Namespace private var selectionNamespace
    @FocusState private var isSearchFocused: Bool

    /// Whether to show search results list (when searching with query)
    private var showSearchResults: Bool {
        appState.isSearchActive && !appState.searchQuery.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar (when active)
            if appState.isSearchActive {
                SearchBarView(
                    searchQuery: $appState.searchQuery,
                    isFocused: $isSearchFocused,
                    onSubmit: {
                        confirmSelection()
                    }
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if showSearchResults {
                // Search results list (shows apps AND specific windows)
                SearchResultsListView(
                    results: appState.searchResults,
                    selectedIndex: appState.selectedSearchIndex,
                    onResultClicked: { index in
                        appState.selectedSearchIndex = index
                        // Update window index if result targets specific window
                        if let result = appState.selectedSearchResult,
                           let windowIndex = result.targetWindowIndex {
                            appState.selectedWindowIndex = windowIndex
                        }
                        confirmSelection()
                    }
                )
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                // App grid (normal mode)
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
                        // Ignore hover if we're in keyboard navigation mode
                        guard !appState.isKeyboardNavigating else { return }
                        appState.selectedAppIndex = index
                        appState.selectedWindowIndex = 0
                    }
                )
                .onContinuousHover { phase in
                    // Re-enable mouse navigation when mouse moves
                    if case .active = phase {
                        appState.markMouseNavigation()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                // Window list for selected app (if it has multiple windows)
                if let selectedApp = appState.selectedApp, selectedApp.hasMultipleWindows {
                    Divider()
                        .padding(.horizontal, 20)

                    WindowListView(
                        app: selectedApp,
                        selectedWindowIndex: appState.selectedWindowIndex,
                        onWindowHovered: { index in
                            // Ignore hover if we're in keyboard navigation mode
                            guard !appState.isKeyboardNavigating else { return }
                            appState.selectedWindowIndex = index
                        },
                        onWindowClicked: { index in
                            appState.selectedWindowIndex = index
                            confirmSelection()
                        }
                    )
                    .onContinuousHover { phase in
                        // Re-enable mouse navigation when mouse moves
                        if case .active = phase {
                            appState.markMouseNavigation()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }

            // Keyboard hints
            keyboardHintsView
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 400, idealWidth: 700, maxWidth: 900)
        .fixedSize(horizontal: false, vertical: true)  // Let height grow to fit content
        .background(GlassBackground(cornerRadius: 20))
        .padding(16)  // Give room for glass effect border/shadow to render without clipping
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.selectedAppIndex)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: appState.selectedSearchIndex)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.isSearchActive)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.searchQuery)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.selectedApp?.hasMultipleWindows)
        .onChange(of: appState.isSearchActive) { oldValue, isActive in
            if isActive {
                isSearchFocused = true
                appState.selectedSearchIndex = 0  // Reset search selection
            }
        }
        .onChange(of: appState.searchQuery) { oldValue, newValue in
            appState.selectedSearchIndex = 0  // Reset selection when query changes
        }
    }

    private var keyboardHintsView: some View {
        HStack(spacing: 12) {
            KeyHint(keys: ["tab"], label: "Next")
            KeyHint(keys: ["`"], label: "Windows")
            KeyHint(keys: ["return"], label: "Search")
            KeyHint(keys: ["esc"], label: "Cancel")
        }
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
        .foregroundStyle(.primary.opacity(0.7))
        .frame(minWidth: 20, minHeight: 18)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            ZStack {
                // Key cap base
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(nsColor: .controlBackgroundColor).opacity(0.9),
                                Color(nsColor: .controlBackgroundColor).opacity(0.7)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Inner highlight
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.3),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )

                // Outer shadow/border
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5)
            }
        )
        .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 1)
    }
}

/// A keyboard hint showing key(s) + description
struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 6) {
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
