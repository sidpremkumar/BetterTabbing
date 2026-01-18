import SwiftUI

struct AppGridView: View {
    let applications: [ApplicationModel]
    let selectedIndex: Int
    let namespace: Namespace.ID
    var onAppClicked: ((Int) -> Void)?
    var onAppHovered: ((Int) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 12)
    ]

    var body: some View {
        if applications.isEmpty {
            emptyStateView
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(Array(applications.enumerated()), id: \.element.id) { index, app in
                    AppTileView(
                        app: app,
                        isSelected: index == selectedIndex,
                        namespace: namespace,
                        onHover: { isHovering in
                            if isHovering {
                                onAppHovered?(index)
                            }
                        }
                    )
                    .id(app.id)
                    .onTapGesture {
                        onAppClicked?(index)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)

            Text("No Applications Found")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Open some applications to switch between them")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding()
    }
}
