import Foundation
import os

// Mirror every log line to the configured cache dir as copycat.log so we can
// `tail -f` it. os.Logger captures the same line — `log stream --subsystem
// com.copycat.macos` for the live structured stream.
enum LogFile {
    // Resolved once at process startup. Settings.cacheDir can change at
    // runtime, but the log file follows the path active when the app
    // launched — chasing it mid-run risks split logs across two locations.
    static let url: URL = {
        let cache = Settings.cacheDir
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        return cache.appendingPathComponent("copycat.log")
    }()

    // Rotate by truncation: when the file exceeds `maxBytes`, rewrite it
    // to retain only the last `keepBytes`. Single-file design — no .log.1
    // shuffling — because the menu-bar app only ever has one writer and
    // 1 MB of recent history is plenty for debugging.
    static let maxBytes: Int = 5 * 1024 * 1024
    static let keepBytes: Int = 1 * 1024 * 1024

    private static let queue = DispatchQueue(label: "com.copycat.macos.logfile")
    private static let stamper: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func append(_ line: String) {
        let stamp = stamper.string(from: Date())
        let entry = "[\(stamp)] \(line)\n"
        queue.async {
            guard let data = entry.data(using: .utf8) else { return }
            truncateIfOversized(at: url, maxBytes: maxBytes, keepBytes: keepBytes)
            if FileManager.default.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// If the file at `url` exceeds `maxBytes`, rewrite it to retain only
    /// the trailing `keepBytes` of content, aligned forward to the next
    /// newline so partial lines never appear at the top of the rotated log.
    /// Pure helper — caller controls path/sizes so this is testable.
    static func truncateIfOversized(at url: URL, maxBytes: Int, keepBytes: Int) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > maxBytes else { return }

        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let offset = max(0, size - keepBytes)
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return }
        let tail = handle.readDataToEndOfFile()

        // Drop any partial line at the very front of the retained slice so
        // the rotated file always begins at a line boundary.
        let aligned: Data
        if let nlIdx = tail.firstIndex(of: 0x0A) {
            aligned = tail.subdata(in: (nlIdx + 1)..<tail.count)
        } else {
            aligned = tail
        }
        try? aligned.write(to: url, options: .atomic)
    }
}

enum LogSubsystem {
    static let id = "com.copycat.macos"
}

enum Log {
    static let app      = AppLogger(category: "App")
    static let tap      = AppLogger(category: "Tap")
    static let cmdV     = AppLogger(category: "Local")
    static let cmdOptV  = AppLogger(category: "Broadcast")
    static let watchdog = AppLogger(category: "Watchdog")
    static let secure   = AppLogger(category: "SecureInput")
}

struct AppLogger {
    let category: String
    private let osLog: Logger

    init(category: String) {
        self.category = category
        self.osLog = Logger(subsystem: LogSubsystem.id, category: category)
    }

    func info(_ msg: String) {
        osLog.info("\(msg, privacy: .public)")
        LogFile.append("\(category): \(msg)")
    }

    func error(_ msg: String) {
        osLog.error("\(msg, privacy: .public)")
        LogFile.append("\(category) ERROR: \(msg)")
    }
}
