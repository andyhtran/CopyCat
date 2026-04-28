import Foundation

struct TailscalePeer: Identifiable, Hashable, Sendable {
    var id: String { hostname }
    let hostname: String
    let online: Bool
    let os: String?
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

    // Full peer list, online or not. Used by the Settings UI to suggest
    // hosts the user can pick from.
    static func allPeers() -> [TailscalePeer] {
        guard let bin = executablePath else { return [] }
        guard let result = runShell(bin, args: ["status", "--json"]) else {
            Log.app.error("tailscale status: spawn failed for \(bin)")
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
        return parseTailscalePeers(json: result.stdout)
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
