import SwiftUI

struct SearchResultsListView: View {
    let results: [SearchResult]
    let selectedIndex: Int
    let onResultClicked: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section header
            HStack {
                Text("Results")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                if results.count > 10 {
                    Text("\(min(results.count, 10)) of \(results.count)")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 4)

            if results.isEmpty {
                // No results state - compact
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("No matches")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                // Results list
                let displayResults = Array(results.prefix(10))

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
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
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) { oldValue, newValue in
                        withAnimation(.easeInOut(duration: 0.1)) {
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

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            Image(nsImage: result.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                // Primary text
                Text(result.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Subtitle
                if let subtitle = result.displaySubtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Window indicator
            if result.targetWindowIndex != nil {
                Image(systemName: "macwindow")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .secondary : .tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5)
                    )
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            } else {
                Color.clear
            }
        }
    }
}
