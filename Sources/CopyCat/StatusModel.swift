import Foundation
import SwiftUI

// Single source of truth for the menu header. The header used to read tap and
// Secure Input state directly off PasteHandler, but those reads aren't
// observable — SwiftUI evaluated them once (at launch, before the tap finished
// installing) and never refreshed, so the menu showed a permanent, wrong
// "Tap off". Publishing the state here makes the header re-render whenever it
// actually changes. PasteHandler is the only writer (on the main thread).
@MainActor
final class StatusModel: ObservableObject {
    static let shared = StatusModel()

    @Published var tapEnabled = false
    /// Label of whoever holds session-wide Secure Input; nil when clear.
    @Published var secureInputBlocker: String?

    // "CopyCat" for the release build, "CopyCat Dev" for the dev build. Read
    // from CFBundleDisplayName (set per-config in build-app.sh) so the two
    // builds are distinguishable in the menu without hardcoding either name.
    let appName: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "CopyCat"
}
