import Foundation

struct TailscalePeer: Identifiable, Hashable, Sendable {
    var id: String { hostname }
    let hostname: String
    let online: Bool
    let os: String?
}

// Single-flight TTL cache for the peer list. Callers sit on latency-critical
// paths — the paste pipeline and menu rendering — and each uncached lookup
// spawns a subprocess that can hang for tens of seconds when tailscaled is
// starved (UDP-blocked networks wedge its internals). The serial queue means
// a burst of concurrent callers rides one fetch: the first spawns it, the
// rest block until it lands and reuse the result via the TTL.
final class TailscaleStatusCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.copycat.macos.tailscale-status")
    private let ttl: TimeInterval
    private var cached: [TailscalePeer]?
    private var fetchedAt = Date.distantPast

    init(ttl: TimeInterval) {
        self.ttl = ttl
    }

    /// `maxAge` overrides the TTL for one call; 0 forces a fresh fetch.
    /// Failures ([] from a timed-out or not-logged-in daemon) are cached
    /// too — retrying a wedged daemon every paste is exactly the stall this
    /// cache exists to prevent, and an empty list fails open (callers skip
    /// filtering and attempt every host).
    func peers(
        maxAge: TimeInterval? = nil,
        now: Date = Date(),
        fetch: () -> [TailscalePeer]
    ) -> [TailscalePeer] {
        queue.sync {
            if let cached, now.timeIntervalSince(fetchedAt) < maxAge ?? ttl {
                return cached
            }
            let fresh = fetch()
            cached = fresh
            fetchedAt = now
            return fresh
        }
    }
}

enum TailscaleDiscovery {
    private static let candidatePaths = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
    ]

    static var executablePath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { executablePath != nil }

    // Normal `status --json` answers from local daemon state in well under a
    // second; only a wedged daemon blows past this. On timeout the peer list
    // comes back empty, which fails open: callers attempt every configured
    // host and SSH's ConnectTimeout does the filtering.
    private static let statusTimeout: TimeInterval = 3

    // TTL trades staleness for latency: a peer that changed state within the
    // window is misjudged for at most 30s, and the SSH timeout already covers
    // attempting a host that just went offline.
    private static let cache = TailscaleStatusCache(ttl: 30)

    /// Cached peer list for latency-sensitive callers (paste path, menu).
    static func allPeers() -> [TailscalePeer] {
        cache.peers(fetch: fetchPeers)
    }

    /// Uncached fetch for the Settings "Refresh peers" button — an explicit
    /// refresh returning 30s-old data would make the button a no-op.
    static func refreshPeers() -> [TailscalePeer] {
        cache.peers(maxAge: 0, fetch: fetchPeers)
    }

    private static func fetchPeers() -> [TailscalePeer] {
        guard let bin = executablePath else { return [] }
        // TAILSCALE_BE_CLI=1: when the bundled Tailscale binary is invoked from
        // a notarized app's subprocess (no TTY), it relaunches the GUI instead
        // of running as CLI. The env var forces CLI mode. See
        // tailscale/tailscale#16063 and #7140.
        let env = ["TAILSCALE_BE_CLI": "1", "PATH": "/usr/bin:/bin"]
        guard let result = runShell(bin, args: ["status", "--json"], env: env, timeout: statusTimeout) else {
            Log.app.error("tailscale status: spawn failed for \(bin)")
            return []
        }
        guard !result.timedOut else {
            Log.app.error("tailscale status timed out after \(Int(statusTimeout))s — daemon unresponsive; treating peers as unknown")
            return []
        }
        guard result.isSuccess else {
            // Common when the user has Tailscale installed but isn't logged in
            // — info, not error, so it doesn't spam the console on every peer
            // refresh.
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.app.info("tailscale status exit=\(result.exitCode): \(stderr)")
            return []
        }
        let peers = parseTailscalePeers(json: result.stdout)
        Log.app.info("tailscale status ok: \(peers.count) peers via \(bin)")
        return peers
    }

    static func onlineHostnames() -> [String] {
        allPeers().filter(\.online).map(\.hostname)
    }
}

/// Pure parser for `tailscale status --json` — exposed so tests can feed
/// in canned JSON without spawning a subprocess.
func parseTailscalePeers(json: String) -> [TailscalePeer] {
    guard let data = json.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let peers = parsed["Peer"] as? [String: [String: Any]] else {
        return []
    }
    return peers.values.compactMap { info in
        guard let hostname = info["HostName"] as? String,
              let online = info["Online"] as? Bool else {
            return nil
        }
        return TailscalePeer(hostname: hostname, online: online, os: info["OS"] as? String)
    }.sorted { $0.hostname.lowercased() < $1.hostname.lowercased() }
}
