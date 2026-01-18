import SwiftUI

struct AppTileView: View {
    let app: ApplicationModel
    let isSelected: Bool
    let namespace: Namespace.ID
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Selection background
                if isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .matchedGeometryEffect(id: "selection-bg", in: namespace)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .matchedGeometryEffect(id: "selection", in: namespace)

                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.4),
                                    Color.accentColor.opacity(0.15)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                        .matchedGeometryEffect(id: "selection-border", in: namespace)
                }

                // Hover state (when not selected)
                if isHovered && !isSelected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                }

                // App icon
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            }
            .frame(width: 76, height: 76)

            // Text area with fixed height to keep icons aligned
            VStack(spacing: 2) {
                // App name
                Text(app.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 84)

                // Window count badge (or empty space to maintain alignment)
                Text(app.hasMultipleWindows ? "\(app.windowCount) windows" : " ")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .opacity(app.hasMultipleWindows ? 1 : 0)
            }
            .frame(height: 28)  // Fixed height for text area
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHover?(true)
            }
        }
    }
}
