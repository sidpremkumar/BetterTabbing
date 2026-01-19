import SwiftUI

struct WindowListView: View {
    let app: ApplicationModel
    let selectedWindowIndex: Int
    var onWindowHovered: ((Int) -> Void)? = nil
    var onWindowClicked: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section header - minimal
            HStack(spacing: 6) {
                Text("Windows")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Text("·")
                    .foregroundStyle(.quaternary)

                HStack(spacing: 3) {
                    KeyCap(symbol: "`")
                    Text("cycle")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(.horizontal, 4)

            // Window list
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }
}
