import Combine
import Foundation

// MARK: - Public types

struct BroadcastHost: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var hostname: String
    var enabled: Bool

    init(id: UUID = UUID(), hostname: String, enabled: Bool = true) {
        self.id = id
        self.hostname = hostname
        self.enabled = enabled
    }
}

// MARK: - Defaults

enum SettingsDefaults {
    // SSH paste off by default; user opts into remote paste explicitly.
    static let enableLocalPaste = true
    static let enableBroadcast  = false
    static let launchAtLogin    = false
    static let showMenuBarIcon  = true

    // Common terminal bundle IDs. Users can add/remove via Settings.
    static let targetBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.github.wez.wezterm",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "dev.warp.Warp-Stable",
    ]

    static let broadcastHotkey: BroadcastHotkey = .cmdV
    static let cacheKeepCount = 50

    static var cacheDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/copycat", isDirectory: true)
    }
}

// MARK: - Static accessors (thread-safe via UserDefaults)

// All handlers (any thread/queue) read through here. UserDefaults is
// thread-safe; these getters intentionally don't cache so a setting change
// from the UI takes effect on the very next paste without restart.
enum Settings {
    private static var ud: UserDefaults { .standard }

    private enum Key {
        static let targetBundleIDs   = "targetBundleIDs"
        static let broadcastHotkey   = "broadcastHotkey"
        static let broadcastHosts    = "broadcastHosts"
        static let cacheDirPath      = "cacheDirPath"
        static let cacheKeepCount    = "cacheKeepCount"
        static let enableLocalPaste  = "enableLocalPaste"
        static let enableBroadcast   = "enableBroadcast"
        static let launchAtLogin     = "launchAtLogin"
        static let showMenuBarIcon   = "showMenuBarIcon"
    }

    static func registerDefaults() {
        ud.register(defaults: [
            Key.enableLocalPaste:  SettingsDefaults.enableLocalPaste,
            Key.enableBroadcast:   SettingsDefaults.enableBroadcast,
            Key.launchAtLogin:     SettingsDefaults.launchAtLogin,
            Key.showMenuBarIcon:   SettingsDefaults.showMenuBarIcon,
            Key.broadcastHotkey:   SettingsDefaults.broadcastHotkey.rawValue,
            Key.cacheKeepCount:    SettingsDefaults.cacheKeepCount,
        ])
    }

    // MARK: - Bool toggles

    static var enableLocalPaste: Bool {
        get { ud.bool(forKey: Key.enableLocalPaste) }
        set { ud.set(newValue, forKey: Key.enableLocalPaste) }
    }

    static var enableBroadcast: Bool {
        get { ud.bool(forKey: Key.enableBroadcast) }
        set { ud.set(newValue, forKey: Key.enableBroadcast) }
    }

    static var launchAtLogin: Bool {
        get { ud.bool(forKey: Key.launchAtLogin) }
        set { ud.set(newValue, forKey: Key.launchAtLogin) }
    }

    // MARK: - Numeric

    static var cacheKeepCount: Int {
        get { ud.integer(forKey: Key.cacheKeepCount) }
        set { ud.set(newValue, forKey: Key.cacheKeepCount) }
    }

    // MARK: - Strings / enums

    static var broadcastHotkey: BroadcastHotkey {
        get { BroadcastHotkey(rawValue: ud.string(forKey: Key.broadcastHotkey) ?? "") ?? SettingsDefaults.broadcastHotkey }
        set { ud.set(newValue.rawValue, forKey: Key.broadcastHotkey) }
    }

    // Stored as the user typed it (may include leading ~). Tilde expansion
    // happens at read time so the prefs are portable across machines/users —
    // pre-expanding to /Users/<them>/foo would break on a sync to /Users/<me>.
    static var cacheDirPath: String {
        get { ud.string(forKey: Key.cacheDirPath) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                ud.removeObject(forKey: Key.cacheDirPath)
            } else {
                ud.set(trimmed, forKey: Key.cacheDirPath)
            }
        }
    }

    static var cacheDir: URL {
        resolveCacheDir(rawPath: ud.string(forKey: Key.cacheDirPath))
    }

    /// Pure resolver — exposed for tests and reused by `cacheDir`. Empty/nil
    /// falls back to the default; otherwise the leading tilde is expanded
    /// against the current user's home dir.
    static func resolveCacheDir(rawPath: String?) -> URL {
        if let path = rawPath, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return SettingsDefaults.cacheDir
    }

    // MARK: - JSON-encoded values

    static var targetBundleIDs: Set<String> {
        get {
            decodeJSON(Key.targetBundleIDs, as: Set<String>.self) ?? SettingsDefaults.targetBundleIDs
        }
        set { encodeJSON(newValue, key: Key.targetBundleIDs) }
    }

    static var broadcastHosts: [BroadcastHost] {
        get { decodeJSON(Key.broadcastHosts, as: [BroadcastHost].self) ?? [] }
        set { encodeJSON(newValue, key: Key.broadcastHosts) }
    }

    static var enabledBroadcastHostnames: [String] {
        broadcastHosts.filter(\.enabled).map(\.hostname)
    }

    // MARK: - JSON helpers

    private static func decodeJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = ud.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encodeJSON<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            ud.set(data, forKey: key)
        }
    }
}

// MARK: - SwiftUI binding layer

// SwiftUI wants @Published bindings; handlers want raw thread-safe reads.
// This class is the binding layer — every setter writes to UserDefaults,
// every external UserDefaults change is rebroadcast, so handlers and the
// UI stay in sync without either knowing about the other.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var enableLocalPaste: Bool      { didSet { Settings.enableLocalPaste = enableLocalPaste } }
    @Published var enableBroadcast: Bool       { didSet { Settings.enableBroadcast = enableBroadcast } }
    @Published var launchAtLogin: Bool         { didSet { Settings.launchAtLogin = launchAtLogin } }

    @Published var targetBundleIDs: Set<String> { didSet { Settings.targetBundleIDs = targetBundleIDs } }

    @Published var broadcastHotkey: BroadcastHotkey { didSet { Settings.broadcastHotkey = broadcastHotkey } }

    @Published var broadcastHosts: [BroadcastHost] { didSet { Settings.broadcastHosts = broadcastHosts } }

    @Published var cacheKeepCount: Int       { didSet { Settings.cacheKeepCount = cacheKeepCount } }
    @Published var cacheDirPath: String      { didSet { Settings.cacheDirPath = cacheDirPath } }

    private init() {
        // SwiftUI may construct this singleton before AppDelegate runs, so
        // ensure defaults are registered before reading any value.
        Settings.registerDefaults()

        self.enableLocalPaste   = Settings.enableLocalPaste
        self.enableBroadcast    = Settings.enableBroadcast
        self.launchAtLogin      = Settings.launchAtLogin
        self.targetBundleIDs    = Settings.targetBundleIDs
        self.broadcastHotkey    = Settings.broadcastHotkey
        self.broadcastHosts     = Settings.broadcastHosts
        self.cacheKeepCount     = Settings.cacheKeepCount
        self.cacheDirPath       = Settings.cacheDirPath
    }
}
