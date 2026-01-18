import SwiftUI

struct WindowListView: View {
    let app: ApplicationModel
    let selectedWindowIndex: Int
    var onWindowHovered: ((Int) -> Void)? = nil
    var onWindowClicked: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Text("Windows")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                HStack(spacing: 4) {
                    KeyCap(symbol: "`")
                    Text("to cycle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 4)

            // Window list with scroll-to-selection
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(app.windows.enumerated()), id: \.element.id) { index, window in
                            WindowRowView(
                                window: window,
                                isSelected: index == selectedWindowIndex,
                                onHover: { isHovering in
                                    if isHovering {
                                        onWindowHovered?(index)
                                    }
                                }
                            )
                            .id(index)
                            .onTapGesture {
                                onWindowClicked?(index)
                            }
                        }
                    }
                }
                .onChange(of: selectedWindowIndex) { oldValue, newValue in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}
