import CoreGraphics
import Foundation

// CGEventFlags values are device-independent — the same flags fire whether
// the user pressed left or right modifier. We only persist the four "main"
// modifiers; flags like .maskNumericPad / .maskHelp would generate false
// non-matches against a user-recorded hotkey.
private let modifierMask: UInt64 =
    CGEventFlags.maskCommand.rawValue |
    CGEventFlags.maskAlternate.rawValue |
    CGEventFlags.maskControl.rawValue |
    CGEventFlags.maskShift.rawValue

struct HotkeyBinding: Equatable, Sendable {
    var keyCode: Int
    var modifiers: UInt64

    init(keyCode: Int, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & modifierMask
    }

    // Virtual keycode 9 = "v" on the US layout — keycodes are positional,
    // so this fires regardless of which character "v" prints.
    // Local paste is intentionally not user-configurable: the whole point of
    // CopyCat is to override ⌘V in terminals.
    static let localPaste = HotkeyBinding(
        keyCode: 9,
        modifiers: CGEventFlags.maskCommand.rawValue
    )

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard Int(keyCode) == self.keyCode else { return false }
        return (flags.rawValue & modifierMask) == modifiers
    }

    var displayString: String {
        var parts = ""
        if (modifiers & CGEventFlags.maskControl.rawValue)   != 0 { parts += "⌃" }
        if (modifiers & CGEventFlags.maskAlternate.rawValue) != 0 { parts += "⌥" }
        if (modifiers & CGEventFlags.maskShift.rawValue)     != 0 { parts += "⇧" }
        if (modifiers & CGEventFlags.maskCommand.rawValue)   != 0 { parts += "⌘" }
        // Every binding in CopyCat targets V; broaden if that ever changes.
        parts += keyCode == 9 ? "V" : "key#\(keyCode)"
        return parts
    }
}

// Fixed set of broadcast chords. ⌘V coincides with local paste — broadcast
// already wins precedence in PasteHandler, so picking ⌘V means broadcast
// effectively replaces local while broadcast is enabled.
enum BroadcastHotkey: String, CaseIterable, Codable, Identifiable, Sendable {
    case cmdV
    case cmdOptV
    case cmdCtrlV
    case cmdShiftV

    var id: String { rawValue }

    var binding: HotkeyBinding {
        let cmd = CGEventFlags.maskCommand.rawValue
        let opt = CGEventFlags.maskAlternate.rawValue
        let ctrl = CGEventFlags.maskControl.rawValue
        let shift = CGEventFlags.maskShift.rawValue
        switch self {
        case .cmdV:      return HotkeyBinding(keyCode: 9, modifiers: cmd)
        case .cmdOptV:   return HotkeyBinding(keyCode: 9, modifiers: cmd | opt)
        case .cmdCtrlV:  return HotkeyBinding(keyCode: 9, modifiers: cmd | ctrl)
        case .cmdShiftV: return HotkeyBinding(keyCode: 9, modifiers: cmd | shift)
        }
    }

    var label: String { binding.displayString }
}
