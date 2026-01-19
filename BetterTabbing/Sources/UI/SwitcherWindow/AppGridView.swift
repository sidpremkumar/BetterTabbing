import SwiftUI

struct AppGridView: View {
    let applications: [ApplicationModel]
    let selectedIndex: Int
    let namespace: Namespace.ID
    var onAppClicked: ((Int) -> Void)?
    var onAppHovered: ((Int) -> Void)?

    private let columns = [
        GridItem(.adaptive(minimum: 76, maximum: 90), spacing: 6)
    ]

    var body: some View {
        if applications.isEmpty {
            emptyStateView
        } else {
            LazyVGrid(columns: columns, spacing: 6) {
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
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            Text("No Applications")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Open some apps to switch")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
        .padding()
    }
}
