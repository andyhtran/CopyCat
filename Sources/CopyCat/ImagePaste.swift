import AppKit
import Foundation

enum ImagePaste {
    static func handleLocal() {
        guard let image = readClipboardImage() else {
            Log.cmdV.info("bail (deferred) — image gone from clipboard between probe and read")
            return
        }

        let cacheDir = Settings.cacheDir
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let stamp = stampString()
        let pngPath = cacheDir.appendingPathComponent("screenshot-\(stamp).png")
        guard savePNG(image: image, to: pngPath) else {
            Log.cmdV.error("saveToFile failed for \(pngPath.path)")
            return
        }

        let outPath = compressIfNeeded(src: pngPath, stamp: stamp, dir: cacheDir, log: Log.cmdV)

        // Local paste always types the absolute path. It works in every
        // paste target (shell, REPL, GUI dialog, config file, sudo'd shell,
        // IDE, …) — unlike `~/`, which only expands inside a shell. The
        // user-visible cosmetic cost is /Users/you/… instead of ~/…, which
        // is fine: this terminal already knows who you are.
        let typed = outPath.path
        DispatchQueue.main.async {
            Typer.type(typed)
        }
        Log.cmdV.info("typed \(typed)")

        // Pruning is best-effort cleanup — push it onto a lower-priority
        // queue so the paste-handler hot path returns sooner.
        let keep = Settings.cacheKeepCount
        DispatchQueue.global(qos: .utility).async {
            pruneScreenshotCache(dir: cacheDir, keep: keep)
        }
    }
}

// JPEG q85 at 2560 maxDim: ~10× smaller than PNG with no visible quality loss
// for UI screenshots, well under Anthropic's per-image API limits. sips reads
// from the on-disk PNG, so we still write that first; on failure we keep it.
private let jpegQuality = 85
private let jpegMaxDim = 2560

func compressIfNeeded(src: URL, stamp: String, dir: URL, log: AppLogger) -> URL {
    let jpgPath = dir.appendingPathComponent("screenshot-\(stamp).jpg")
    if compressJPEG(src: src, dst: jpgPath, quality: jpegQuality, maxDim: jpegMaxDim) {
        try? FileManager.default.removeItem(at: src)
        return jpgPath
    }
    log.error("sips compress failed; falling back to PNG")
    return src
}

func compressJPEG(src: URL, dst: URL, quality: Int, maxDim: Int) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    p.arguments = [
        "-s", "format", "jpeg",
        "-s", "formatOptions", "\(quality)",
        "-Z", "\(maxDim)",
        src.path,
        "--out", dst.path,
    ]
    // Detach stdin so sips doesn't inherit any TTY and hang.
    p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
    p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    p.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    } catch {
        return false
    }
}

func readClipboardImage() -> NSImage? {
    guard let objects = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil),
          let image = objects.first as? NSImage else {
        return nil
    }
    return image
}

func stampString() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: Date())
}

func savePNG(image: NSImage, to url: URL) -> Bool {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        return false
    }
    do {
        try png.write(to: url)
        return true
    } catch {
        return false
    }
}

// Only prune files that match our naming scheme. Avoids nuking the log file
// or anything else the user has dropped in this directory.
func pruneScreenshotCache(dir: URL, keep: Int) {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }

    let screenshots = files.filter { $0.lastPathComponent.hasPrefix("screenshot-") }
    let dated = screenshots.compactMap { url -> (URL, Date)? in
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return date.map { (url, $0) }
    }
    .sorted { $0.1 > $1.1 }

    guard dated.count > keep else { return }
    for (url, _) in dated[keep...] {
        try? fm.removeItem(at: url)
    }
}

