import SwiftUI

struct CircularProgressRing: View {
    let progress: CGFloat
    var color: Color = .red
    var lineWidth: CGFloat = 4
    var size: CGFloat = 70

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: lineWidth)

            // Progress
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    color.opacity(0.8),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
    }
}
