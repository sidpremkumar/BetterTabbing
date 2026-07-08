import SwiftUI

struct SearchBarView: View {
    @Binding var searchQuery: String
    @FocusState.Binding var isFocused: Bool
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search apps and windows...", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onAppear {
                    // @FocusState is unreliable with nonactivatingPanel NSPanels.
                    // Walk the AppKit responder chain to force focus on the NSTextField.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isFocused = true
                        forceFocusSearchField()
                    }
                }
                .onSubmit {
                    onSubmit()
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }
}

/// Force-focus the first NSTextField found in the key window's view hierarchy.
/// This bypasses SwiftUI's @FocusState which is unreliable inside nonactivatingPanel NSPanels.
@MainActor
private func forceFocusSearchField() {
    guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0 is SwitcherPanel }) else { return }
    if let textField = findTextField(in: window.contentView) {
        window.makeKey()
        window.makeFirstResponder(textField)
    }
}

@MainActor
private func findTextField(in view: NSView?) -> NSTextField? {
    guard let view = view else { return nil }
    if let tf = view as? NSTextField, tf.isEditable {
        return tf
    }
    for subview in view.subviews {
        if let found = findTextField(in: subview) {
            return found
        }
    }
    return nil
}
