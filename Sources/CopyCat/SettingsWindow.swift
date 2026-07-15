import AppKit
import Combine
import SwiftUI

// Hosts the SwiftUI SettingsView in a vanilla NSWindow, driving tab
// selection through an NSToolbar to match the look the SwiftUI Settings
// scene gives for free. SettingsNavigation.shared.selectedTab is the
// source of truth — both the toolbar and the SwiftUI content read from it.
@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private let nav = SettingsNavigation.shared
    private var navObserver: AnyCancellable?

    // Single source of truth for tab → toolbar mapping. Adding a tab is one
    // edit here plus a case in SettingsView's switch.
    private struct TabSpec {
        let tab: SettingsTab
        let id: NSToolbarItem.Identifier
        let label: String
        let symbol: String
    }

    private static let specs: [TabSpec] = [
        TabSpec(tab: .general,   id: .init("general"),  label: "General",
                symbol: "gearshape"),
        TabSpec(tab: .apps,      id: .init("apps"),     label: "Apps",
                symbol: "app.badge"),
        TabSpec(tab: .broadcast, id: .init("sshHosts"), label: "SSH hosts",
                symbol: "antenna.radiowaves.left.and.right"),
    ]

    private static func spec(for tab: SettingsTab) -> TabSpec? {
        specs.first { $0.tab == tab }
    }

    private static func spec(for id: NSToolbarItem.Identifier) -> TabSpec? {
        specs.first { $0.id == id }
    }

    init(updaterController: UpdaterProviding?) {
        let host = NSHostingController(
            rootView: SettingsView()
                .environment(\.updaterController, updaterController)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "CopyCat Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CopyCatSettingsWindow")
        window.center()

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "CopyCatSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.selectedItemIdentifier = Self.spec(for: nav.selectedTab)?.id

        window.toolbar = toolbar
        window.toolbarStyle = .preference

        // Keep the toolbar in sync when something else (e.g. the "Configure…"
        // submenu button) changes the active tab while the window is open.
        navObserver = nav.$selectedTab.sink { [weak toolbar] tab in
            let newId = Self.spec(for: tab)?.id
            guard toolbar?.selectedItemIdentifier != newId else { return }
            toolbar?.selectedItemIdentifier = newId
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.specs.map(\.id)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let spec = Self.spec(for: id) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.action = #selector(selectTab(_:))
        item.label = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        return item
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        if let spec = Self.spec(for: sender.itemIdentifier) {
            nav.selectedTab = spec.tab
        }
    }
}
