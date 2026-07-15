import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: Hashable {
    case general
    case apps
    case broadcast
}

// Drives the active tab from outside the Settings window — lets menu items
// (e.g. "Configure…" in the SSH hosts submenu) deep-link to a tab.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab = .general
    private init() {}
}

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        // Tab switching is driven by the host window's NSToolbar
        // (SettingsWindowController), which writes nav.selectedTab. Using a
        // switch here instead of TabView avoids SwiftUI rendering its own
        // segmented tab bar on top of the toolbar.
        Group {
            switch nav.selectedTab {
            case .general:   GeneralSettingsView()
            case .apps:      AppsSettingsView()
            case .broadcast: HostsSettingsView()
            }
        }
        .frame(width: 460, height: 500)
        .windowFocusSink()
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @Environment(\.updaterController) private var updaterController
    @ObservedObject private var store = SettingsStore.shared

    // Bound directly to the same UserDefaults key as the App scene's
    // @AppStorage so writes from this toggle propagate to MenuBarExtra
    // immediately. Routing through SettingsStore (raw UserDefaults.set) does
    // not reliably notify @AppStorage observers.
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon: Bool = true
    @State private var autoUpdateEnabled = true

    var body: some View {
        Form {
            Section("App") {
                Toggle("Launch at login", isOn: $store.launchAtLogin)
                    .onChange(of: store.launchAtLogin) { _, new in
                        LaunchAtLogin.setEnabled(new)
                    }
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { autoUpdateEnabled },
                        set: {
                            autoUpdateEnabled = $0
                            updaterController?.automaticallyChecksForUpdates = $0
                        }
                    )
                )

                LabeledContent("Check for updates") {
                    updateCheckContent
                }

                if let reason = updaterController?.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Pasting") {
                Toggle(
                    "Enable local paste (\(HotkeyBinding.localPaste.displayString))",
                    isOn: $store.enableLocalPaste)
                Toggle("Enable SSH paste", isOn: $store.enableBroadcast)
                Picker("SSH hotkey", selection: $store.broadcastHotkey) {
                    ForEach(BroadcastHotkey.allCases) { chord in
                        Text(chord.label).tag(chord)
                    }
                }
                .disabled(!store.enableBroadcast)
            }

            Section("Cache") {
                LabeledContent("Local cache") {
                    HStack {
                        TextField("", text: $store.cacheDirPath, prompt: Text("~/.cache/copycat"))
                            .textFieldStyle(.roundedBorder)
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([Settings.cacheDir])
                        }
                    }
                }
                Stepper(value: $store.cacheKeepCount, in: 5...500, step: 5) {
                    Text("Keep most recent: \(store.cacheKeepCount) screenshots")
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppVersionInfo.current.displayString)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 4)
        .onAppear {
            autoUpdateEnabled = updaterController?.automaticallyChecksForUpdates ?? true
        }
    }

    /// Mirrors the live update state next to the Check Now button, since the
    /// menu (where the full banner lives) may be closed while the user is in
    /// this window.
    @ViewBuilder private var updateCheckContent: some View {
        switch updaterController?.updateViewModel.state ?? .idle {
        case .idle:
            checkNowButton

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }

        case .updateAvailable(let update):
            Button("Install \(update.version)") {
                update.install()
            }

        case .downloading(let download):
            Text(
                download.fraction.map { "Downloading… \(Int($0 * 100))%" }
                    ?? "Downloading…"
            )
            .foregroundStyle(.secondary)
            .monospacedDigit()

        case .extracting:
            Text("Preparing…")
                .foregroundStyle(.secondary)

        case .installing:
            Text("Installing… CopyCat will relaunch")
                .foregroundStyle(.secondary)

        case .notFound:
            Text("You're up to date")
                .foregroundStyle(.secondary)

        case .failed:
            HStack(spacing: 8) {
                Text("Update failed")
                    .foregroundStyle(.secondary)
                checkNowButton
            }
        }
    }

    private var checkNowButton: some View {
        Button("Check Now") {
            guard updaterController?.updateViewModel.state.allowsManualCheck == true else {
                return
            }
            updaterController?.checkForUpdates(nil)
        }
        .disabled(updateCheckDisabled)
    }

    private var updateCheckDisabled: Bool {
        guard let updaterController, updaterController.isAvailable else {
            return true
        }
        return !updaterController.updateViewModel.state.allowsManualCheck
    }
}

// MARK: - Apps (target bundle IDs)

private struct AppsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CopyCat only intercepts paste in apps listed here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top)

            List {
                ForEach(sortedBundleIDs(), id: \.self) { id in
                    AppRow(bundleID: id, onRemove: { remove(id) })
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            HStack {
                Button("Add App…", action: addAppViaPicker)
                Button("Reset to Defaults") {
                    store.targetBundleIDs = SettingsDefaults.targetBundleIDs
                }
                Spacer()
            }
            .padding()
        }
    }

    private func sortedBundleIDs() -> [String] {
        store.targetBundleIDs.sorted()
    }

    private func remove(_ id: String) {
        store.targetBundleIDs.remove(id)
    }

    private func addAppViaPicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Pick an app to enable CopyCat paste interception in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
            store.targetBundleIDs.insert(id)
        }
    }
}

private struct AppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 22, height: 22)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).font(.body)
                Text(bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private var displayName: String {
        guard let url = appURL,
            let bundle = Bundle(url: url)
        else {
            return bundleID
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
    }

    private var appIcon: NSImage? {
        guard let url = appURL else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - SSH hosts

private struct HostsSettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var peers: [TailscalePeer] = []
    @State private var newHostname: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Configured hosts") {
                    if store.broadcastHosts.isEmpty {
                        Text("No hosts configured. Add from Tailscale peers below or by hostname.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach($store.broadcastHosts) { $host in
                            HStack {
                                Toggle("", isOn: $host.enabled).labelsHidden()
                                TextField("hostname", text: $host.hostname)
                                    .textFieldStyle(.roundedBorder)
                                Button(role: .destructive, action: { remove(host) }) {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        // Invisible toggle reserves the same leading width as
                        // the populated rows so the TextFields share a left
                        // edge and a width. opacity(0) preserves layout where
                        // .hidden() didn't render reliably here.
                        Toggle("", isOn: .constant(false))
                            .labelsHidden()
                            .opacity(0)
                            .allowsHitTesting(false)
                        TextField("Add hostname", text: $newHostname)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addCustom() }
                        Button(action: addCustom) {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .disabled(newHostname.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Tailscale peers") {
                    if !TailscaleDiscovery.isAvailable {
                        Text("Tailscale not installed.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if peers.isEmpty {
                        Text("No peers found (or `tailscale status` failed).")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(peers) { peer in
                            HStack {
                                Circle()
                                    .fill(peer.online ? Color.green : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text(peer.hostname).font(.body)
                                if let os = peer.os, !os.isEmpty {
                                    Text(os).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") { add(peer.hostname) }
                                    .disabled(alreadyConfigured(peer.hostname))
                            }
                        }
                    }
                    Button("Refresh peers", action: refreshPeers)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear(perform: refreshPeers)
    }

    private func refreshPeers() {
        // tailscale status --json takes ~300-500ms; keep it off the main thread
        // so opening the Settings window doesn't stall.
        Task.detached(priority: .userInitiated) {
            let fresh = TailscaleDiscovery.allPeers()
            await MainActor.run { peers = fresh }
        }
    }

    private func remove(_ host: BroadcastHost) {
        store.broadcastHosts.removeAll { $0.id == host.id }
    }

    private func add(_ hostname: String) {
        guard !alreadyConfigured(hostname) else { return }
        store.broadcastHosts.append(BroadcastHost(hostname: hostname))
    }

    private func addCustom() {
        let trimmed = newHostname.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        add(trimmed)
        newHostname = ""
    }

    private func alreadyConfigured(_ hostname: String) -> Bool {
        store.broadcastHosts.contains { $0.hostname == hostname }
    }
}
