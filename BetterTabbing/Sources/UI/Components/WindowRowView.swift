import SwiftUI

struct WindowRowView: View {
    let window: WindowModel
    let isSelected: Bool
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Window icon indicator
            Image(systemName: window.isMinimized ? "minus.rectangle" : "macwindow")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                // Window title
                Text(window.title)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // Subtitle (URL, file path, etc.)
                if let subtitle = window.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Minimized indicator
            if window.isMinimized {
                Text("minimized")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 200, maxWidth: 300)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.05))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            }
        )
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHover?(true)
            }
        }
    }
}
