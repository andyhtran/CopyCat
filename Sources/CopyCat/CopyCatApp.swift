import AppKit
import SwiftUI

@main
struct CopyCatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Resolve once at startup. SwiftUI's MenuBarExtra(_:image:) form expects
    // an asset-catalog name, which we don't have — feeding NSImage directly
    // through the custom-label form sidesteps that lookup.
    private let menuBarIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        Log.app.error("MenuBarIcon.pdf missing from bundle — using system fallback")
        let fallback = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "CopyCat")
            ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }()

    var body: some Scene {
        MenuBarExtra {
            CopyCatMenu()
        } label: {
            Image(nsImage: menuBarIcon)
                .accessibilityLabel("CopyCat")
        }

        SwiftUI.Settings {
            SettingsView()
        }
    }
}

private struct CopyCatMenu: View {
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        StatusHeader()
        Divider()

        Toggle("Local paste (\(HotkeyBinding.localPaste.displayString))", isOn: $store.enableLocalPaste)
        Toggle("SSH paste (\(store.broadcastHotkey.label))", isOn: $store.enableBroadcast)

        Divider()

        BroadcastHostsMenu()

        Menu("Recent screenshots") {
            RecentScreenshotsMenu()
        }

        Menu("Options") {
            Button("Reveal cache folder") {
                NSWorkspace.shared.open(Settings.cacheDir)
            }
            Button("Reveal log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
            }
            Button("Open log file") {
                NSWorkspace.shared.open(LogFile.url)
            }
            Divider()
            Button("Open Accessibility settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit CopyCat") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private struct StatusHeader: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        let tapEnabled = AppDelegate.shared?.pasteHandler?.isTapEnabled == true
        let tapText = tapEnabled ? "Tap on" : "Tap off"

        Text("CopyCat — \(tapText)")
            .font(.headline)

        if store.enableBroadcast {
            let hostText = broadcastStatusLine()
            Text(hostText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func broadcastStatusLine() -> String {
        let configured = store.broadcastHosts.filter(\.enabled).map(\.hostname)
        if configured.isEmpty {
            return "No SSH hosts configured"
        }
        let online = Set(TailscaleDiscovery.onlineHostnames())
        let onlineCount: Int
        if TailscaleDiscovery.isAvailable && !online.isEmpty {
            onlineCount = configured.filter { online.contains($0) }.count
        } else {
            onlineCount = configured.count
        }

        let snap = BroadcastStatus.shared.snapshot()
        if let date = snap.date {
            let ago = relativeTime(from: date)
            return "\(onlineCount)/\(configured.count) host(s) reachable · last \(ago)"
        }
        return "\(onlineCount)/\(configured.count) host(s) reachable"
    }

    private func relativeTime(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

private struct BroadcastHostsMenu: View {
    @ObservedObject private var store = SettingsStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu("SSH hosts") {
            if store.broadcastHosts.isEmpty {
                Text("No hosts configured")
            } else {
                Section("Configured") {
                    ForEach($store.broadcastHosts) { $host in
                        Toggle(host.hostname, isOn: $host.enabled)
                    }
                }
            }
            Divider()
            Button("Configure…") {
                SettingsNavigation.shared.selectedTab = .broadcast
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
        }
    }
}

private struct RecentScreenshotsMenu: View {
    var body: some View {
        let recents = recentScreenshots(in: Settings.cacheDir, limit: 8)
        if recents.isEmpty {
            Text("No screenshots yet").foregroundStyle(.secondary)
        } else {
            ForEach(recents, id: \.absoluteString) { url in
                Button(url.lastPathComponent) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private func recentScreenshots(in dir: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        let screenshots = files.filter { $0.lastPathComponent.hasPrefix("screenshot-") }
        let dated = screenshots.compactMap { url -> (URL, Date)? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return date.map { (url, $0) }
        }
        .sorted { $0.1 > $1.1 }
        return Array(dated.prefix(limit).map(\.0))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?

    var pasteHandler: PasteHandler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Settings.registerDefaults()

        NSApp.setActivationPolicy(.accessory)
        Log.app.info("CopyCat launching (pid=\(ProcessInfo.processInfo.processIdentifier))")

        // Reconcile launch-at-login with the saved preference. SMAppService
        // can drift if the app moved or was reinstalled.
        let stored = Settings.launchAtLogin
        if stored != LaunchAtLogin.isEnabled {
            LaunchAtLogin.setEnabled(stored)
        }

        pasteHandler = PasteHandler()
        pasteHandler?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("CopyCat terminating")
        pasteHandler?.stop()
    }
}
