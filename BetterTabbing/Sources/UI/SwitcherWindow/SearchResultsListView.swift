import SwiftUI

struct SearchResultsListView: View {
    let results: [SearchResult]
    let selectedIndex: Int
    let onResultClicked: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Text("Results")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(min(results.count, 10)) of \(results.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 4)

            if results.isEmpty {
                // No results state
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No matches found")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                // Results list - dynamic height up to max, then scrollable
                let displayResults = Array(results.prefix(15))
                let rowHeight: CGFloat = 52  // Approximate height per row
                let maxVisibleRows = 8
                let contentHeight = CGFloat(displayResults.count) * rowHeight
                let maxHeight = CGFloat(maxVisibleRows) * rowHeight

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: displayResults.count > maxVisibleRows) {
                        VStack(spacing: 2) {
                            ForEach(Array(displayResults.enumerated()), id: \.element.id) { index, result in
                                SearchResultRowView(
                                    result: result,
                                    isSelected: index == selectedIndex
                                )
                                .id(index)
                                .onTapGesture {
                                    onResultClicked(index)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: min(contentHeight, maxHeight))
                    .onChange(of: selectedIndex) { oldValue, newValue in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(newValue, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

struct SearchResultRowView: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // App icon with subtle shadow
            Image(nsImage: result.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                // Primary text (window title or app name)
                Text(result.displayName)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Subtitle (app name for windows, window title for apps)
                if let subtitle = result.displaySubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Window indicator when targeting specific window
            if result.targetWindowIndex != nil {
                Image(systemName: "macwindow")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .secondary : .tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                if isSelected {
                    // Selected state - vibrant highlight
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.2))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.5),
                                    Color.accentColor.opacity(0.2)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
            }
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}
