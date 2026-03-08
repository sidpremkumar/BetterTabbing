import SwiftUI

// MARK: - Colorblind-safe palette derived from process name hash

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

private func colorForName(_ name: String) -> Color {
    var hash: UInt64 = 5381
    for byte in name.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
    }
    return hashPalette[Int(hash % UInt64(hashPalette.count))]
}

// MARK: - Resource Monitor View

// MARK: - Process Grouping

/// A group of processes with similar names, shown as a collapsible row
private struct ProcessGroup: Identifiable {
    let id: String // base name
    let displayName: String
    let entries: [ProcessResourceMonitor.ProcessResourceEntry]

    var totalMemoryBytes: UInt64 { entries.reduce(0) { $0 + $1.memoryBytes } }
    var totalCpuPercent: Double { entries.reduce(0) { $0 + $1.cpuPercent } }
    var isGroup: Bool { entries.count > 1 }

    var formattedMemory: String {
        let mb = Double(totalMemoryBytes) / (1024 * 1024)
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        else if mb >= 1 { return "\(Int(mb)) MB" }
        else { return "<1 MB" }
    }

    var formattedCPU: String {
        if totalCpuPercent >= 100 { return String(format: "%.0f%%", totalCpuPercent) }
        else if totalCpuPercent >= 0.1 { return String(format: "%.1f%%", totalCpuPercent) }
        else { return "0%" }
    }
}

/// Extract a base name by stripping parenthesized/bracketed suffixes and colon-delimited tails
private func processBaseName(_ name: String) -> String {
    var result = name
    // Remove parenthesized content: "Cursor Helper (Renderer)" → "Cursor Helper"
    while let range = result.range(of: "\\s*\\([^)]*\\)", options: .regularExpression) {
        result.removeSubrange(range)
    }
    // Remove bracketed content: "tsserver[5.3.0-dev...]" → "tsserver"
    while let range = result.range(of: "\\s*\\[[^\\]]*\\]", options: .regularExpression) {
        result.removeSubrange(range)
    }
    // Remove everything after colon: "foo: bar" → "foo"
    if let colonIdx = result.firstIndex(of: ":") {
        result = String(result[..<colonIdx])
    }
    return result.trimmingCharacters(in: .whitespaces)
}

/// Group entries by base name similarity. Preserves rank order (first occurrence).
private func groupEntries(_ entries: [ProcessResourceMonitor.ProcessResourceEntry]) -> [ProcessGroup] {
    var groupMap: [String: [ProcessResourceMonitor.ProcessResourceEntry]] = [:]
    var groupOrder: [String] = []

    for entry in entries {
        let base = processBaseName(entry.name)
        if groupMap[base] == nil {
            groupOrder.append(base)
        }
        groupMap[base, default: []].append(entry)
    }

    return groupOrder.compactMap { base in
        guard let items = groupMap[base], !items.isEmpty else { return nil }
        return ProcessGroup(id: base, displayName: base, entries: items)
    }
}

// MARK: - Resource Monitor View

struct ResourceMonitorView: View {
    let entries: [ProcessResourceMonitor.ProcessResourceEntry]
    let systemMemory: ProcessResourceMonitor.SystemMemory?
    let systemCPU: ProcessResourceMonitor.SystemCPU?
    let cpuTemperature: Double?
    let thermalState: ProcessInfo.ThermalState
    let cpuHistory: [Double]
    let memoryHistory: [Double]
    let aiInsight: String?
    let aiInsightLoading: Bool
    let ollamaAvailable: Bool
    let isEHoldActive: Bool
    let eHoldProgress: CGFloat
    let isGroupingEnabled: Bool
    let onRefreshInsight: () -> Void

    private var chartEntries: [ProcessResourceMonitor.ProcessResourceEntry] {
        Array(entries.prefix(6))
    }

    private var totalProcessMemory: UInt64 {
        entries.reduce(0) { $0 + $1.memoryBytes }
    }

    private var totalSystemBytes: UInt64 {
        systemMemory?.totalBytes ?? totalProcessMemory
    }

    private var systemUsedBytes: UInt64 {
        systemMemory?.usedBytes ?? totalProcessMemory
    }

    private var chartMemory: UInt64 {
        chartEntries.reduce(0) { $0 + $1.memoryBytes }
    }

    private var otherProcessMemory: UInt64 {
        totalProcessMemory > chartMemory ? totalProcessMemory - chartMemory : 0
    }

    private var systemOverhead: UInt64 {
        systemUsedBytes > totalProcessMemory ? systemUsedBytes - totalProcessMemory : 0
    }

    private var freeBytes: UInt64 {
        systemMemory?.freeBytes ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerView

            if entries.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Sampling...")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                // Top row: CPU gauge + Temperature gauge + live graph
                HStack(spacing: 12) {
                    // CPU gauge
                    MiniGauge(
                        value: systemCPU?.usagePercent ?? 0,
                        maxValue: 100,
                        label: "CPU",
                        formattedValue: String(format: "%.0f%%", systemCPU?.usagePercent ?? 0),
                        color: cpuColor
                    )
                    .frame(width: 70, height: 70)

                    // Memory gauge
                    MiniGauge(
                        value: systemMemory?.usedFraction ?? 0,
                        maxValue: 1.0,
                        label: "MEM",
                        formattedValue: "\(systemMemory?.usedPercent ?? 0)%",
                        color: memoryColor
                    )
                    .frame(width: 70, height: 70)

                    // Temperature gauge
                    TemperatureGauge(
                        temperature: cpuTemperature,
                        thermalState: thermalState,
                        size: 70
                    )
                    .frame(width: 70, height: 70)

                    // Live sparkline graph
                    VStack(alignment: .leading, spacing: 2) {
                        LiveGraph(
                            cpuHistory: cpuHistory,
                            memoryHistory: memoryHistory
                        )
                    }
                }
                .padding(.horizontal, 4)

                // AI Insight bar (shows status even when Ollama is offline)
                AIInsightBar(
                    insight: aiInsight,
                    isLoading: aiInsightLoading,
                    ollamaAvailable: ollamaAvailable,
                    isEHoldActive: isEHoldActive,
                    eHoldProgress: eHoldProgress,
                    onRefresh: onRefreshInsight
                )
                .padding(.horizontal, 4)

                // System memory bar
                SystemMemoryBar(
                    usedBytes: systemUsedBytes,
                    totalBytes: totalSystemBytes
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

                    Text("CPU")
                        .frame(width: 55, alignment: .trailing)
                    Text("MEM")
                        .frame(width: 60, alignment: .trailing)
                    Text("%RAM")
                        .frame(width: 42, alignment: .trailing)
                }
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.quaternary)
                .textCase(.uppercase)
                .tracking(0.3)
                .padding(.horizontal, 14)

                // Process list
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        if isGroupingEnabled {
                            let groups = groupEntries(entries)
                            ForEach(groups) { group in
                                if group.isGroup {
                                    GroupHeaderRowView(
                                        group: group,
                                        totalSystemBytes: totalSystemBytes
                                    )
                                    ForEach(group.entries) { entry in
                                        ResourceRowView(
                                            entry: entry,
                                            rank: nil,
                                            totalSystemBytes: totalSystemBytes,
                                            isIndented: true
                                        )
                                    }
                                } else {
                                    ResourceRowView(
                                        entry: group.entries[0],
                                        rank: nil,
                                        totalSystemBytes: totalSystemBytes,
                                        isIndented: false
                                    )
                                }
                            }
                        } else {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                ResourceRowView(
                                    entry: entry,
                                    rank: index + 1,
                                    totalSystemBytes: totalSystemBytes,
                                    isIndented: false
                                )
                            }
                        }
                    }
                }
                .frame(maxHeight: 350)
            }
        }
    }

    private var thermalStateText: String {
        switch thermalState {
        case .nominal:  return "Cool"
        case .fair:     return "Warm"
        case .serious:  return "Hot"
        case .critical: return "Critical"
        @unknown default: return "?"
        }
    }

    private var cpuColor: Color {
        guard let cpu = systemCPU else { return .green }
        switch cpu.usagePercent {
        case 0..<40:  return Color(hue: 0.35, saturation: 0.60, brightness: 0.80)
        case 40..<70: return Color(hue: 0.10, saturation: 0.70, brightness: 0.95)
        default:      return Color(hue: 0.00, saturation: 0.65, brightness: 0.90)
        }
    }

    private var memoryColor: Color {
        guard let mem = systemMemory else { return .green }
        switch mem.usedPercent {
        case 0..<60:  return Color(hue: 0.35, saturation: 0.60, brightness: 0.80)
        case 60..<80: return Color(hue: 0.10, saturation: 0.70, brightness: 0.95)
        default:      return Color(hue: 0.00, saturation: 0.65, brightness: 0.90)
        }
    }

    @ViewBuilder
    private var headerView: some View {
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

            // Live indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                    .opacity(entries.isEmpty ? 0.3 : 1.0)

                Text("LIVE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(entries.isEmpty ? Color.white.opacity(0.2) : Color.green.opacity(0.8))
            }

            // RAM summary
            if let mem = systemMemory {
                Text("\(mem.formattedUsed) / \(mem.formattedTotal)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            // Temperature badge — always visible when we have data
            HStack(spacing: 3) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(thermalBadgeColor)

                if let t = cpuTemperature {
                    Text(String(format: "%.0f°C", t))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(thermalBadgeColor)
                } else {
                    Text(thermalStateText)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(thermalBadgeColor)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(thermalBadgeColor.opacity(0.12))
            )
        }
        .padding(.horizontal, 4)
    }

    private var thermalBadgeColor: Color {
        if let t = cpuTemperature {
            switch t {
            case ..<50:   return Color(hue: 0.55, saturation: 0.60, brightness: 0.95) // blue
            case 50..<70: return Color(hue: 0.35, saturation: 0.60, brightness: 0.80) // green
            case 70..<85: return Color(hue: 0.10, saturation: 0.70, brightness: 0.95) // orange
            default:      return Color(hue: 0.00, saturation: 0.70, brightness: 0.90) // red
            }
        }
        switch thermalState {
        case .nominal:  return Color(hue: 0.35, saturation: 0.60, brightness: 0.80) // green
        case .fair:     return Color(hue: 0.15, saturation: 0.70, brightness: 0.95) // yellow
        case .serious:  return Color(hue: 0.10, saturation: 0.70, brightness: 0.95) // orange
        case .critical: return Color(hue: 0.00, saturation: 0.70, brightness: 0.90) // red
        @unknown default: return .gray
        }
    }
}

// MARK: - Mini Gauge (CPU / Memory arc gauge)

private struct MiniGauge: View {
    let value: Double
    let maxValue: Double
    let label: String
    let formattedValue: String
    let color: Color

    private var fraction: Double {
        guard maxValue > 0 else { return 0 }
        return min(value / maxValue, 1.0)
    }

    var body: some View {
        ZStack {
            // Background arc
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))

            // Value arc
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeInOut(duration: 0.4), value: fraction)

            // Center text
            VStack(spacing: 1) {
                Text(formattedValue)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
    }
}

// MARK: - Temperature Gauge

private struct TemperatureGauge: View {
    let temperature: Double?
    let thermalState: ProcessInfo.ThermalState
    let size: CGFloat

    /// Fraction from 0 (30°C) to 1 (110°C) for exact temp,
    /// or mapped from thermal state when temp unavailable
    private var fraction: Double {
        if let t = temperature {
            return min(max((t - 30) / 80.0, 0), 1.0)
        }
        // Map thermal state to approximate gauge position
        switch thermalState {
        case .nominal:  return 0.2
        case .fair:     return 0.45
        case .serious:  return 0.7
        case .critical: return 0.95
        @unknown default: return 0.2
        }
    }

    private var gaugeColor: Color {
        if let t = temperature {
            switch t {
            case ..<50:   return Color(hue: 0.55, saturation: 0.60, brightness: 0.95) // cool blue
            case 50..<70: return Color(hue: 0.35, saturation: 0.60, brightness: 0.80) // green
            case 70..<85: return Color(hue: 0.10, saturation: 0.70, brightness: 0.95) // orange
            default:      return Color(hue: 0.00, saturation: 0.70, brightness: 0.90) // red
            }
        }
        switch thermalState {
        case .nominal:  return Color(hue: 0.35, saturation: 0.60, brightness: 0.80) // green
        case .fair:     return Color(hue: 0.15, saturation: 0.70, brightness: 0.95) // yellow
        case .serious:  return Color(hue: 0.10, saturation: 0.70, brightness: 0.95) // orange
        case .critical: return Color(hue: 0.00, saturation: 0.70, brightness: 0.90) // red
        @unknown default: return .gray
        }
    }

    private var stateLabel: String {
        switch thermalState {
        case .nominal:  return "Cool"
        case .fair:     return "Warm"
        case .serious:  return "Hot"
        case .critical: return "Crit"
        @unknown default: return "?"
        }
    }

    var body: some View {
        ZStack {
            // Background arc
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))

            // Value arc
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(gaugeColor.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.easeInOut(duration: 0.4), value: fraction)

            // Center text
            VStack(spacing: 1) {
                if let t = temperature {
                    // Exact temperature available (Intel)
                    Text(String(format: "%.0f°", t))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                } else {
                    // Thermal state only (Apple Silicon)
                    Text(stateLabel)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                Text("TEMP")
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
    }
}

// MARK: - Live Graph (CPU + Memory sparklines)

private struct LiveGraph: View {
    let cpuHistory: [Double]
    let memoryHistory: [Double]

    private let graphHeight: CGFloat = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Legend
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(hue: 0.55, saturation: 0.70, brightness: 0.95))
                        .frame(width: 10, height: 3)
                    Text("CPU")
                        .font(.system(size: 7, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Color(hue: 0.10, saturation: 0.70, brightness: 0.95))
                        .frame(width: 10, height: 3)
                    Text("MEM")
                        .font(.system(size: 7, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("60s")
                    .font(.system(size: 7, weight: .medium, design: .rounded))
                    .foregroundStyle(.quaternary)
            }

            // Graph area
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack(alignment: .bottomLeading) {
                    // Grid lines at 25%, 50%, 75%
                    ForEach([25.0, 50.0, 75.0], id: \.self) { pct in
                        Path { path in
                            let y = h - (h * pct / 100.0)
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                    }

                    // CPU line
                    if cpuHistory.count > 1 {
                        sparklinePath(data: cpuHistory, width: w, height: h)
                            .stroke(
                                Color(hue: 0.55, saturation: 0.70, brightness: 0.95).opacity(0.9),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                            )

                        // CPU fill
                        sparklineArea(data: cpuHistory, width: w, height: h)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(hue: 0.55, saturation: 0.70, brightness: 0.95).opacity(0.2),
                                        Color(hue: 0.55, saturation: 0.70, brightness: 0.95).opacity(0.02)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    // Memory line
                    if memoryHistory.count > 1 {
                        sparklinePath(data: memoryHistory, width: w, height: h)
                            .stroke(
                                Color(hue: 0.10, saturation: 0.70, brightness: 0.95).opacity(0.9),
                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                            )

                        sparklineArea(data: memoryHistory, width: w, height: h)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(hue: 0.10, saturation: 0.70, brightness: 0.95).opacity(0.15),
                                        Color(hue: 0.10, saturation: 0.70, brightness: 0.95).opacity(0.02)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }

                    // "Waiting for data" placeholder
                    if cpuHistory.count <= 1 {
                        Text("Collecting data...")
                            .font(.system(size: 9))
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(height: graphHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// Build a sparkline Path for the given data (0-100 range) across the width
    private func sparklinePath(data: [Double], width: CGFloat, height: CGFloat) -> Path {
        let maxPoints = 60
        return Path { path in
            guard data.count > 1 else { return }
            let count = data.count
            let xStep = width / CGFloat(maxPoints - 1)
            // Start from the right side (most recent data)
            let startX = width - CGFloat(count - 1) * xStep

            for (i, value) in data.enumerated() {
                let x = startX + CGFloat(i) * xStep
                let y = height - (height * min(value, 100) / 100.0)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    /// Build a filled area under the sparkline
    private func sparklineArea(data: [Double], width: CGFloat, height: CGFloat) -> Path {
        let maxPoints = 60
        return Path { path in
            guard data.count > 1 else { return }
            let count = data.count
            let xStep = width / CGFloat(maxPoints - 1)
            let startX = width - CGFloat(count - 1) * xStep

            // Top edge (the sparkline)
            for (i, value) in data.enumerated() {
                let x = startX + CGFloat(i) * xStep
                let y = height - (height * min(value, 100) / 100.0)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // Close along the bottom
            let endX = startX + CGFloat(count - 1) * xStep
            path.addLine(to: CGPoint(x: endX, y: height))
            path.addLine(to: CGPoint(x: startX, y: height))
            path.closeSubpath()
        }
    }
}

// MARK: - System Memory Bar

private struct SystemMemoryBar: View {
    let usedBytes: UInt64
    let totalBytes: UInt64

    private var usedPercent: Int {
        guard totalBytes > 0 else { return 0 }
        return Int(round(Double(usedBytes) / Double(totalBytes) * 100))
    }

    private var usedFraction: CGFloat {
        guard totalBytes > 0 else { return 0 }
        return CGFloat(usedBytes) / CGFloat(totalBytes)
    }

    private var barColor: Color {
        switch usedPercent {
        case 0..<60:  return Color(hue: 0.35, saturation: 0.60, brightness: 0.80)
        case 60..<80: return Color(hue: 0.10, saturation: 0.70, brightness: 0.95)
        default:      return Color(hue: 0.00, saturation: 0.65, brightness: 0.90)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.06))

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor.opacity(0.7).gradient)
                        .frame(width: max(usedFraction * geo.size.width, 2))
                        .animation(.easeInOut(duration: 0.3), value: usedFraction)

                    HStack {
                        Spacer()
                        Text("\(usedPercent)% used")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                        Spacer()
                    }
                }
            }
            .frame(height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            HStack {
                Label {
                    Text(formatBytes(usedBytes) + " used")
                } icon: {
                    Circle().fill(barColor).frame(width: 6, height: 6)
                }

                Spacer()

                let freeBytes = totalBytes > usedBytes ? totalBytes - usedBytes : 0
                Label {
                    Text(formatBytes(freeBytes) + " free")
                } icon: {
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6)
                }
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.tertiary)
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(Int(Double(bytes) / (1024 * 1024))) MB"
    }
}

// MARK: - Group Header Row

private struct GroupHeaderRowView: View {
    let group: ProcessGroup
    let totalSystemBytes: UInt64

    @State private var isHovered = false

    private var percentOfRAM: Int {
        guard totalSystemBytes > 0 else { return 0 }
        return Int(round(Double(group.totalMemoryBytes) / Double(totalSystemBytes) * 100))
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(colorForName(group.displayName))
                .frame(width: 6, height: 6)

            Text("\(group.entries.count)x")
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .trailing)

            Text(group.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(group.formattedCPU)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(cpuColor)
                .frame(width: 55, alignment: .trailing)

            Text(group.formattedMemory)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 60, alignment: .trailing)

            Text("\(percentOfRAM)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ramPercentColor)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.03))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in isHovered = hovering }
    }

    private var cpuColor: Color {
        switch group.totalCpuPercent {
        case 0..<5:   return .secondary
        case 5..<30:  return Color(hue: 0.10, saturation: 0.70, brightness: 0.95).opacity(0.9)
        default:      return Color(hue: 0.00, saturation: 0.65, brightness: 0.90).opacity(0.9)
        }
    }

    private var ramPercentColor: Color {
        switch percentOfRAM {
        case 0..<5:   return .secondary
        case 5..<15:  return Color(hue: 0.10, saturation: 0.70, brightness: 0.95).opacity(0.9)
        default:      return Color(hue: 0.00, saturation: 0.65, brightness: 0.90).opacity(0.9)
        }
    }
}

// MARK: - Row View

private struct ResourceRowView: View {
    let entry: ProcessResourceMonitor.ProcessResourceEntry
    let rank: Int?
    let totalSystemBytes: UInt64
    var isIndented: Bool = false

    @State private var isHovered = false

    private var percentOfRAM: Int {
        guard totalSystemBytes > 0 else { return 0 }
        return Int(round(Double(entry.memoryBytes) / Double(totalSystemBytes) * 100))
    }

    var body: some View {
        HStack(spacing: 8) {
            if isIndented {
                // Indented child: thin connector line + smaller dot
                Spacer().frame(width: 6)
                Circle()
                    .fill(colorForName(entry.name).opacity(0.5))
                    .frame(width: 4, height: 4)
                Spacer().frame(width: 4)
            } else {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(colorForName(entry.name))
                    .frame(width: 6, height: 6)

                if let rank = rank {
                    Text("\(rank)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.quaternary)
                        .frame(width: 14, alignment: .trailing)
                } else {
                    Spacer().frame(width: 14)
                }
            }

            Text(entry.name)
                .font(.system(size: isIndented ? 10 : 11, weight: .regular))
                .foregroundStyle(isIndented ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(entry.formattedCPU)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(cpuColor)
                .frame(width: 55, alignment: .trailing)

            Text(entry.formattedMemory)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary.opacity(isIndented ? 0.6 : 0.8))
                .frame(width: 60, alignment: .trailing)

            Text("\(percentOfRAM)%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(ramPercentColor)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isIndented ? 4 : 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var cpuColor: Color {
        switch entry.cpuPercent {
        case 0..<5:   return .secondary
        case 5..<30:  return Color(hue: 0.10, saturation: 0.70, brightness: 0.95).opacity(0.9)
        default:      return Color(hue: 0.00, saturation: 0.65, brightness: 0.90).opacity(0.9)
        }
    }

    private var ramPercentColor: Color {
        switch percentOfRAM {
        case 0..<5:   return .secondary
        case 5..<15:  return Color(hue: 0.10, saturation: 0.70, brightness: 0.95).opacity(0.9)
        default:      return Color(hue: 0.00, saturation: 0.65, brightness: 0.90).opacity(0.9)
        }
    }
}

// MARK: - AI Insight Bar

private struct AIInsightBar: View {
    let insight: String?
    let isLoading: Bool
    let ollamaAvailable: Bool
    let isEHoldActive: Bool
    let eHoldProgress: CGFloat
    let onRefresh: () -> Void

    @State private var isHovered = false
    @State private var shimmerPhase: CGFloat = 0

    /// Whether the charging animation should display
    private var showCharging: Bool {
        isEHoldActive && eHoldProgress > 0
    }

    var body: some View {
        HStack(spacing: 6) {
            // Icon
            Image(systemName: "sparkles")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(iconColor)

            if showCharging {
                // Charging state — show "Charging AI..." with animated dots
                HStack(spacing: 4) {
                    Text("Charging AI…")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.purple.opacity(0.9))
                }
                Spacer()
            } else if !ollamaAvailable && insight == nil && !isLoading {
                // Ollama not running — hint about hold-E
                Text("Hold E for AI insight")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.quaternary)
                Spacer()
            } else if isLoading {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                    Text("Analyzing...")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if let insight = insight {
                Text(insight)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                // Refresh button
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Refresh insight")
            } else {
                Text(ollamaAvailable ? "Ollama ready — hold E for insight" : "Hold E for AI insight")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.quaternary)
                Spacer()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            ZStack(alignment: .leading) {
                // Base background
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.purple.opacity(backgroundOpacity))

                // Charging progress bar — fills from left to right
                if showCharging {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            // Progress fill
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.purple.opacity(0.25),
                                            Color.purple.opacity(0.35),
                                            Color(hue: 0.75, saturation: 0.5, brightness: 1.0).opacity(0.3)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(geo.size.width * eHoldProgress, 4))
                                .animation(.easeOut(duration: 0.05), value: eHoldProgress)

                            // Shimmer effect at the leading edge of progress
                            if eHoldProgress > 0.05 && eHoldProgress < 1.0 {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.15))
                                    .frame(width: 20)
                                    .offset(x: geo.size.width * eHoldProgress - 20)
                                    .blur(radius: 4)
                                    .animation(.easeOut(duration: 0.05), value: eHoldProgress)
                            }
                        }
                    }
                }

                // Border
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        showCharging ? Color.purple.opacity(0.3) : Color.purple.opacity(ollamaAvailable ? 0.1 : 0.05),
                        lineWidth: showCharging ? 1.0 : 0.5
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in isHovered = hovering }
    }

    private var iconColor: Color {
        if showCharging {
            return Color.purple.opacity(0.9)
        }
        return ollamaAvailable ? Color.purple.opacity(0.8) : Color.white.opacity(0.2)
    }

    private var backgroundOpacity: Double {
        if showCharging { return 0.06 }
        if isHovered && ollamaAvailable { return 0.08 }
        return 0.04
    }
}
