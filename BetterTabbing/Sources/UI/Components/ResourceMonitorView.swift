import SwiftUI

struct ResourceMonitorView: View {
    let entries: [ProcessResourceMonitor.ProcessResourceEntry]

    /// Top entries for the bar chart (max 5)
    private var chartEntries: [ProcessResourceMonitor.ProcessResourceEntry] {
        Array(entries.prefix(5))
    }

    /// Total memory across all entries (for percentage calculation)
    private var totalMemory: UInt64 {
        entries.reduce(0) { $0 + $1.memoryBytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header — matches SearchResultsListView style
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)

                    Text("Resource Monitor")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                Spacer()

                if totalMemory > 0 {
                    Text(formattedTotal)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 4)

            if entries.isEmpty {
                // Empty state
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.0percent")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("No data available")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                // Bar chart — top 5 processes as horizontal proportional bars
                MemoryBarChart(entries: chartEntries, totalMemory: totalMemory)
                    .padding(.horizontal, 4)

                // Divider between chart and list
                Divider()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)

                // Column headers for the list
                HStack(spacing: 8) {
                    Spacer()
                        .frame(width: 5 + 8 + 14) // dot + spacing + rank width

                    Text("Process")
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("MEM")
                        .frame(width: 60, alignment: .trailing)
                    Text("CPU")
                        .frame(width: 50, alignment: .trailing)
                }
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .padding(.horizontal, 14)

                // Process list
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            ResourceRowView(entry: entry, rank: index + 1)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
    }

    private var formattedTotal: String {
        let gb = Double(totalMemory) / (1024 * 1024 * 1024)
        return String(format: "Total: %.1f GB", gb)
    }
}

// MARK: - Bar Chart

private struct MemoryBarChart: View {
    let entries: [ProcessResourceMonitor.ProcessResourceEntry]
    let totalMemory: UInt64

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Stacked horizontal bar
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(entries) { entry in
                        let fraction = totalMemory > 0
                            ? CGFloat(entry.memoryBytes) / CGFloat(totalMemory)
                            : 0

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(barColor(for: entry).gradient)
                            .frame(width: max(fraction * geo.size.width, 2))
                    }

                    // "Other" segment for remaining memory
                    let topMemory = entries.reduce(UInt64(0)) { $0 + $1.memoryBytes }
                    if topMemory < totalMemory {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.08).gradient)
                    }
                }
            }
            .frame(height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            // Legend — small labels under the chart
            HStack(spacing: 10) {
                ForEach(entries) { entry in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(barColor(for: entry))
                            .frame(width: 5, height: 5)

                        Text(abbreviate(entry.name))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(entry.formattedMemory)
                            .font(.system(size: 8, weight: .regular, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func barColor(for entry: ProcessResourceMonitor.ProcessResourceEntry) -> Color {
        switch entry.memoryTier {
        case 3:  return .red.opacity(0.75)
        case 2:  return .orange.opacity(0.7)
        case 1:  return .yellow.opacity(0.6)
        default: return .green.opacity(0.5)
        }
    }

    /// Abbreviate long process names for the legend
    private func abbreviate(_ name: String) -> String {
        if name.count <= 10 { return name }
        return String(name.prefix(8)) + "..."
    }
}

// MARK: - Row View

private struct ResourceRowView: View {
    let entry: ProcessResourceMonitor.ProcessResourceEntry
    let rank: Int

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Memory tier indicator dot
            Circle()
                .fill(tierColor)
                .frame(width: 5, height: 5)

            // Rank number
            Text("\(rank)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.quaternary)
                .frame(width: 14, alignment: .trailing)

            // Process name
            Text(entry.name)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Memory value
            Text(entry.formattedMemory)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(memoryTextColor)
                .frame(width: 60, alignment: .trailing)

            // CPU time
            Text(entry.formattedCPU)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    /// Color for the tier indicator dot
    private var tierColor: Color {
        switch entry.memoryTier {
        case 3:  return .red.opacity(0.8)
        case 2:  return .orange.opacity(0.7)
        case 1:  return .yellow.opacity(0.6)
        default: return .green.opacity(0.4)
        }
    }

    /// Text color for memory value — more emphasis on high usage
    private var memoryTextColor: Color {
        switch entry.memoryTier {
        case 3:  return .red.opacity(0.9)
        case 2:  return .orange.opacity(0.85)
        default: return .secondary
        }
    }
}
