import SwiftUI

@main
struct BetterTabbingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        // Menu bar only - no dock icon
        MenuBarExtra("BetterTabbing", systemImage: "rectangle.stack") {
            MenuBarView()
                .environmentObject(appState)
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    private var shortcutDisplay: String {
        appState.preferences.useSystemShortcut ? "⌘ TAB" : "⌥ TAB"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BetterTabbing")
                .font(.headline)

            Divider()

            HStack {
                Text("Shortcut:")
                Spacer()
                Text(shortcutDisplay)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Preferences...") {
                print("[MenuBar] Preferences button clicked")
                NotificationCenter.default.post(name: .openPreferences, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit BetterTabbing") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(8)
    }
}

// Placeholder for PreferencesView
struct PreferencesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ShortcutSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            AboutView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 450, height: 300)
        .environmentObject(appState)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $appState.preferences.launchAtLogin)
            }

            Section("Activation Shortcut") {
                Picker("Shortcut", selection: $appState.preferences.useSystemShortcut) {
                    Text("⌥ OPTION + TAB (Recommended)")
                        .tag(false)
                    Text("⌘ CMD + TAB (Replaces system)")
                        .tag(true)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.preferences.useSystemShortcut) { _, newValue in
                    // Notify the event tap to update its modifier
                    let modifier: ModifierKey = newValue ? .command : .option
                    NotificationCenter.default.post(
                        name: .activationModifierChanged,
                        object: nil,
                        userInfo: ["modifier": modifier]
                    )
                }

                if appState.preferences.useSystemShortcut {
                    Text("This will intercept the system CMD+TAB shortcut. The native app switcher will be replaced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Windows") {
                Toggle("Show windows from all Spaces", isOn: $appState.preferences.showAllSpaces)
                Toggle("Show minimized windows", isOn: $appState.preferences.showMinimizedWindows)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("While Switcher is Open") {
                KeyboardShortcutRow(title: "Next application", shortcut: "TAB")
                KeyboardShortcutRow(title: "Previous application", shortcut: "⇧ TAB")
                KeyboardShortcutRow(title: "Next window", shortcut: "`")
                KeyboardShortcutRow(title: "Previous window", shortcut: "⇧ `")
                KeyboardShortcutRow(title: "Search", shortcut: "Return")
                KeyboardShortcutRow(title: "Confirm", shortcut: "Release modifier")
                KeyboardShortcutRow(title: "Cancel", shortcut: "Escape")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct KeyboardShortcutRow: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(shortcut)
                .foregroundStyle(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("BetterTabbing")
                .font(.title)
                .fontWeight(.bold)

            Text("Version 1.0.0")
                .foregroundStyle(.secondary)

            Text("A better CMD+TAB experience for macOS")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding()
    }
}
