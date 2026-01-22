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

            ExcludedAppsSettingsView()
                .tabItem {
                    Label("Excluded Apps", systemImage: "eye.slash")
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
        .frame(width: 450, height: 350)
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

struct ExcludedAppsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var runningApps: [(name: String, bundleID: String, icon: NSImage)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Excluded apps will not appear in the switcher.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            List {
                ForEach(runningApps, id: \.bundleID) { app in
                    let isExcluded = appState.preferences.excludedBundleIDs.contains(app.bundleID)
                    HStack(spacing: 10) {
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                        Text(app.name)
                            .lineLimit(1)
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { isExcluded },
                            set: { exclude in
                                if exclude {
                                    appState.preferences.excludedBundleIDs.append(app.bundleID)
                                } else {
                                    appState.preferences.excludedBundleIDs.removeAll { $0 == app.bundleID }
                                }
                                WindowCache.shared.invalidate()
                                WindowCache.shared.prefetchAsync()
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .onAppear {
            loadRunningApps()
        }
    }

    private func loadRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app -> (name: String, bundleID: String, icon: NSImage)? in
                guard let name = app.localizedName,
                      let bundleID = app.bundleIdentifier else { return nil }
                let icon = app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
                return (name: name, bundleID: bundleID, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Include currently excluded apps that aren't running (so user can un-exclude them)
        var result = apps
        for bundleID in appState.preferences.excludedBundleIDs {
            if !result.contains(where: { $0.bundleID == bundleID }) {
                let name = bundleID.components(separatedBy: ".").last ?? bundleID
                result.append((name: name, bundleID: bundleID, icon: NSImage(named: NSImage.applicationIconName) ?? NSImage()))
            }
        }

        runningApps = result
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
