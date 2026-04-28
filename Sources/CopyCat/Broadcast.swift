import AppKit
import Foundation

// Broadcast sends every screenshot to every configured host. The alternative
// — detecting which terminal window is SSH'd to which host — needs window
// title parsing and a process tree, both of which break across app restarts
// and tab reorderings. Broadcast is stateless and survives all of that.
// Works because every host caches under `~/.cache/copycat/` relative to its
// own home, so the typed path resolves on each machine. Cost: every host
// gets every screenshot; negligible on a LAN with `cacheKeepCount` pruning.

// ssh -o ConnectTimeout — drops genuinely-unreachable hosts (Tailscale peer
// missing or stale-online) without making the broadcast logger wait too long.
// 5s is enough for a normal Tailscale handshake on a flaky link.
private let sshConnectTimeoutSeconds = 5

// Remote cache dir, relative to the SSH user's home. XDG-standard cache path;
// matches the local default so the typed `~/.cache/copycat/foo.jpg` resolves
// on either side.
private let remoteCacheRel = ".cache/copycat"

enum Broadcast {
    static func handle() {
        guard let image = readClipboardImage() else {
            Log.cmdOptV.info("bail (deferred) — image gone from clipboard between probe and read")
            return
        }

        let cacheDir = Settings.cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let stamp = stampString()
        let pngPath = cacheDir.appendingPathComponent("screenshot-\(stamp).png")

        guard savePNG(image: image, to: pngPath) else {
            Log.cmdOptV.error("saveToFile failed for \(pngPath.path)")
            return
        }

        Log.cmdOptV.info("starting compress for \(stamp)")
        let outPath = compressIfNeeded(src: pngPath, stamp: stamp, dir: cacheDir, log: Log.cmdOptV)
        let outName = outPath.lastPathComponent

        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: outPath.path)[.size] as? Int) ?? 0
        let sizeKB = sizeBytes / 1024

        let configured = Settings.enabledBroadcastHostnames
        let hosts = filterToReachableHosts(configured)

        if hosts.isEmpty {
            if configured.isEmpty {
                Log.cmdOptV.info("no hosts configured — local only (\(sizeKB)KB)")
            } else {
                Log.cmdOptV.info("no configured hosts online — local only (\(sizeKB)KB)")
            }
        } else {
            Log.cmdOptV.info("broadcast → \(hosts.joined(separator: ", ")) (\(sizeKB)KB)")
            broadcastUpload(
                name: outName,
                src: outPath,
                hosts: hosts,
                keepCount: Settings.cacheKeepCount
            )
        }

        // Remote home dir is unknown, so always tilde-prefix.
        let typed = "~/\(remoteCacheRel)/\(outName)"
        DispatchQueue.main.async {
            Typer.type(typed)
        }
        Log.cmdOptV.info("typed \(typed)")

        BroadcastStatus.shared.recordRun(hosts: hosts)

        // Prune off the SSH-fanout path on a lower-priority queue so
        // Broadcast.handle returns as soon as the typing has been scheduled.
        let keep = Settings.cacheKeepCount
        DispatchQueue.global(qos: .utility).async {
            pruneScreenshotCache(dir: cacheDir, keep: keep)
        }
    }

    // If Tailscale is installed, prefer to skip hosts whose Tailscale peer
    // status is offline. If Tailscale isn't installed or the host isn't a
    // Tailscale peer, attempt anyway and let SSH's connect timeout handle it.
    static func filterToReachableHosts(_ candidates: [String]) -> [String] {
        let peers = TailscaleDiscovery.allPeers()
        guard !peers.isEmpty else {
            // Either Tailscale isn't installed or the user has no peers.
            // Don't filter — let SSH ConnectTimeout do the filtering.
            return candidates
        }
        let online = Set(peers.lazy.filter(\.online).map(\.hostname))
        let known = Set(peers.lazy.map(\.hostname))
        return candidates.filter { host in
            guard known.contains(host) else {
                return true   // not a Tailscale peer; attempt anyway
            }
            return online.contains(host)
        }
    }
}

// Last-broadcast status surfaced in the menu bar.
final class BroadcastStatus: @unchecked Sendable {
    static let shared = BroadcastStatus()

    private let queue = DispatchQueue(label: "com.copycat.macos.broadcaststatus")
    private var lastRunDate: Date?
    private var lastHosts: [String] = []

    func recordRun(hosts: [String]) {
        queue.sync {
            lastRunDate = Date()
            lastHosts = hosts
        }
    }

    func snapshot() -> (date: Date?, hosts: [String]) {
        queue.sync { (lastRunDate, lastHosts) }
    }
}

func broadcastUpload(
    name: String,
    src: URL,
    hosts: [String],
    keepCount: Int
) {
    // Remote pruning matches the local pruning policy. Only files matching
    // our naming scheme would be in this dir under normal operation, but
    // we restrict the rm by sort+tail anyway in case the user dropped
    // something in there.
    let remoteCmd = """
    mkdir -p ~/\(remoteCacheRel) && \
    cat > ~/\(remoteCacheRel)/\(name) && \
    cd ~/\(remoteCacheRel) && \
    ls -t | tail -n +\(keepCount + 1) | xargs -I{} rm -f -- {}
    """

    for host in hosts {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = sshArgs(
                host: host,
                remoteCmd: remoteCmd,
                connectTimeout: sshConnectTimeoutSeconds
            )
            guard let inputHandle = try? FileHandle(forReadingFrom: src) else {
                Log.cmdOptV.error("broadcast → \(host): could not open \(src.path)")
                return
            }
            p.standardInput = inputHandle
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            do {
                try p.run()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    Log.cmdOptV.error("broadcast → \(host) failed (exit=\(p.terminationStatus)): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            } catch {
                Log.cmdOptV.error("broadcast → \(host) spawn failed: \(error.localizedDescription)")
            }
        }
    }
}

/// SSH argv builder. The leading `--` separator is load-bearing: without it,
/// a hostname starting with `-` (e.g. `-oProxyCommand=touch /tmp/pwned`) is
/// parsed by ssh as an option flag. The user has to add such a hostname
/// themselves so this isn't a remote-attack surface, but the foot-gun is
/// trivial to remove.
func sshArgs(host: String, remoteCmd: String, connectTimeout: Int) -> [String] {
    [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=\(connectTimeout)",
        "--",
        host,
        remoteCmd,
    ]
}

struct ShellResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var isSuccess: Bool { exitCode == 0 }
}

/// Runs a process with stdin detached, capturing stdout and stderr separately
/// so callers can distinguish "no output" from "failed silently". Returns
/// `nil` only when the process couldn't be spawned at all (bad path, etc).
func runShell(_ exec: String, args: [String]) -> ShellResult? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exec)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
    do {
        try p.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ShellResult(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: p.terminationStatus
        )
    } catch {
        return nil
    }
}
