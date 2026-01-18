import SwiftUI

/// Liquid Glass background using macOS 26 glassEffect
struct GlassBackground: View {
    var cornerRadius: CGFloat = 20

    var body: some View {
        // Use Color.clear as the base and let glassEffect handle the shape
        Color.clear
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
    }
}

#Preview {
    GlassBackground(cornerRadius: 20)
        .frame(width: 300, height: 200)
}
