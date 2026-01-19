import SwiftUI

struct AppTileView: View {
    let app: ApplicationModel
    let isSelected: Bool
    let namespace: Namespace.ID  // Kept for API compatibility but not used
    var onHover: ((Bool) -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Selection/hover background
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(backgroundColor)

                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(0.5),
                                    Color.accentColor.opacity(0.2)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }

                // App icon
                Image(nsImage: app.icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
            }
            .frame(width: 64, height: 64)

            // App name with window count inline
            HStack(spacing: 4) {
                Text(app.name)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if app.hasMultipleWindows {
                    Text("·\(app.windowCount)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: 76)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHover?(true)
            }
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.2)
        } else if isHovered {
            return Color.white.opacity(0.08)
        } else {
            return Color.clear
        }
    }
}
