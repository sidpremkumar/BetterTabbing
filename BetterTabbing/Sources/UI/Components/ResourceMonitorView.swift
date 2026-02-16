import SwiftUI

// MARK: - Colorblind-safe palette derived from process name hash

/// 10 perceptually distinct colors safe for all common forms of color blindness.
/// Based on Wong (2011) optimized palette + extras, chosen for contrast against
/// dark/glass backgrounds and mutual distinguishability under deuteranopia,
/// protanopia, and tritanopia.
private let hashPalette: [Color] = [
    Color(hue: 0.58, saturation: 0.70, brightness: 0.95),  // cornflower blue
    Color(hue: 0.08, saturation: 0.80, brightness: 0.95),  // tangerine
    Color(hue: 0.85, saturation: 0.55, brightness: 0.90),  // soft magenta
    Color(hue: 0.45, saturation: 0.65, brightness: 0.85),  // teal
    Color(hue: 0.15, saturation: 0.75, brightness: 1.00),  // amber / gold
    Color(hue: 0.72, saturation: 0.50, brightness: 0.95),  // lavender
    Color(hue: 0.00, saturation: 0.65, brightness: 0.90),  // coral red
    Color(hue: 0.35, saturation: 0.60, brightness: 0.80),  // sage green
    Color(hue: 0.55, saturation: 0.35, brightness: 1.00),  // sky / powder blue
    Color(hue: 0.95, saturation: 0.60, brightness: 0.95),  // rose pink
]

/// Deterministic color from a process name. Same name always yields same color.
private func colorForName(_ name: String) -> Color {
    // djb2 hash — fast, good distribution
    var hash: UInt64 = 5381
    for byte in name.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
    }
    return hashPalette[Int(hash % UInt64(hashPalette.count))]
}

// MARK: - Resource Monitor View

struct ResourceMonitorView: View {
    let entries: [ProcessResourceMonitor.ProcessResourceEntry]

    /// Top entries for the bar chart (max 6)
    private var chartEntries: [ProcessResourceMonitor.ProcessResourceEntry] {
        Array(entries.prefix(6))
    }

    /// Total memory across ALL entries
    private var totalMemory: UInt64 {
        entries.reduce(0) { $0 + $1.memoryBytes }
    }

    /// Memory consumed by chart entries
    private var chartMemory: UInt64 {
        chartEntries.reduce(0) { $0 + $1.memoryBytes }
    }

    /// Memory in the "Other" bucket
    private var otherMemory: UInt64 {
        totalMemory > chartMemory ? totalMemory - chartMemory : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
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
                // Bar chart
                MemoryBarChart(
                    entries: chartEntries,
                    totalMemory: totalMemory,
                    otherMemory: otherMemory
                )
                .padding(.horizontal, 4)

                Divider()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)

                // Column headers
                HStack(spacing: 8) {
                    Spacer()
                        .frame(width: 5 + 8 + 14)

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
    let otherMemory: UInt64

    private var otherPercent: Int {
        guard totalMemory > 0 else { return 0 }
        return Int(round(Double(otherMemory) / Double(totalMemory) * 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Stacked horizontal bar
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(entries) { entry in
                        let fraction = totalMemory > 0
                            ? CGFloat(entry.memoryBytes) / CGFloat(totalMemory)
                            : 0

                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(colorForName(entry.name).opacity(0.85).gradient)
                            .frame(width: max(fraction * (geo.size.width - CGFloat(entries.count)), 4))
                    }

                    // "Other" segment
                    if otherMemory > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.12).gradient)
                    }
                }
            }
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // Legend — wrapping rows of labels
            legendView
        }
    }

    @ViewBuilder
    private var legendView: some View {
        // Use two rows if needed: first row = entries, second row if > 3 + other
        let items = entries.map { entry in
            LegendItem(
                name: abbreviate(entry.name),
                detail: entry.formattedMemory,
                percent: percent(for: entry),
                color: colorForName(entry.name)
            )
        }
        let otherItem = otherMemory > 0 ? LegendItem(
            name: "Other",
            detail: formatBytes(otherMemory),
            percent: otherPercent,
            color: Color.white.opacity(0.35)
        ) : nil

        let allItems = otherItem.map { items + [$0] } ?? items

        // Split into two rows of ~4 if we have more than 4
        if allItems.count <= 4 {
            HStack(spacing: 10) {
                ForEach(Array(allItems.enumerated()), id: \.offset) { _, item in
                    legendLabel(item)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    ForEach(Array(allItems.prefix(4).enumerated()), id: \.offset) { _, item in
                        legendLabel(item)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    ForEach(Array(allItems.dropFirst(4).enumerated()), id: \.offset) { _, item in
                        legendLabel(item)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func legendLabel(_ item: LegendItem) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(item.color)
                .frame(width: 8, height: 8)

            Text(item.name)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text("\(item.percent)%")
                .font(.system(size: 8, weight: .regular, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func percent(for entry: ProcessResourceMonitor.ProcessResourceEntry) -> Int {
        guard totalMemory > 0 else { return 0 }
        return Int(round(Double(entry.memoryBytes) / Double(totalMemory) * 100))
    }

    private func abbreviate(_ name: String) -> String {
        if name.count <= 10 { return name }
        return String(name.prefix(8)) + "\u{2026}"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return "\(Int(mb)) MB"
    }
}

private struct LegendItem {
    let name: String
    let detail: String
    let percent: Int
    let color: Color
}

// MARK: - Row View

private struct ResourceRowView: View {
    let entry: ProcessResourceMonitor.ProcessResourceEntry
    let rank: Int

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Color dot — matches bar chart color
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(colorForName(entry.name))
                .frame(width: 6, height: 6)

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
                .foregroundStyle(.primary.opacity(0.8))
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
}
