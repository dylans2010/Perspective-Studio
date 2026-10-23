import Foundation
#if os(macOS)
import CoreGraphics
#endif

/// Keyboard input via CGEvent.
///
/// - `type` inserts text as Unicode events, character by character,
///   so any script/emoji works and apps receive realistic key events.
///   Newlines are sent as a real Return press and tabs as a real Tab
///   press, because many fields treat a pasted "\n" differently from
///   the Return key.
/// - `press` sends one named key (Return, Escape, arrows, F-keys…).
/// - `shortcut` sends a key with explicit modifiers.
///
/// Nothing here logs or returns the typed text — see
/// `ComputerUseSafety.redactedTextSummary`.
public enum ComputerUseKeyboard {

    /// ANSI virtual keycodes (kVK_* values) for every named key this
    /// layer supports, keyed by normalised name.
    public static let keycodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "command": 55, "cmd": 55, "shift": 56,
        "capslock": 57, "option": 58, "alt": 58, "control": 59, "ctrl": 59,
        "rightshift": 60, "rightoption": 61, "rightcontrol": 62,
        "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121, "help": 114,
        "left": 123, "leftarrow": 123, "right": 124, "rightarrow": 124,
        "down": 125, "downarrow": 125, "up": 126, "uparrow": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
        "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106,
        "f17": 64
    ]

    /// Canonical modifier names accepted in shortcuts.
    public static let modifierAliases: [String: String] = [
        "cmd": "command", "command": "command", "meta": "command", "super": "command",
        "shift": "shift",
        "option": "option", "alt": "option", "opt": "option",
        "control": "control", "ctrl": "control", "ctl": "control",
        "fn": "fn", "function": "fn",
        "capslock": "capslock"
    ]

    /// Parses a shortcut spec like "command+shift+p" into its key and
    /// canonical modifier set. Pure — unit-tested without hardware.
    /// Returns nil for malformed specs (empty, modifier-only, unknown
    /// modifier, unknown key).
    public static func parseShortcut(_ spec: String) -> (key: String, modifiers: Set<String>)? {
        let parts = spec.lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let key = parts.last else { return nil }
        guard keycodes[key] != nil, modifierAliases[key] == nil else { return nil }
        var modifiers: Set<String> = []
        for part in parts.dropLast() {
            guard let canonical = modifierAliases[part] else { return nil }
            modifiers.insert(canonical)
        }
        return (key, modifiers)
    }

    /// Normalises a key name for `press` ("Return", "ESC", "→" …).
    public static func normalizedKeyName(_ raw: String) -> String? {
        var name = raw.lowercased().trimmingCharacters(in: .whitespaces)
        switch name {
        case "→": name = "right"
        case "←": name = "left"
        case "↑": name = "up"
        case "↓": name = "down"
        case "⏎", "↵": name = "return"
        case "␣": name = "space"
        default: break
        }
        return keycodes[name] != nil ? name : nil
    }

    #if os(macOS)
    private static func postKey(virtualKey: UInt16, keyDown: Bool, flags: CGEventFlags = []) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: keyDown) else {
            throw ComputerUseError.executionFailed("Could not create a keyboard CGEvent for key \(virtualKey).")
        }
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
    }

    private static func flags(for modifiers: Set<String>) -> CGEventFlags {
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option": flags.insert(.maskAlternate)
            case "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            case "capslock": flags.insert(.maskAlphaShift)
            default: break
            }
        }
        return flags
    }

    /// Types text into the currently focused field.
    public static func type(_ text: String) async throws {
        guard text.count <= ComputerUseSafety.Limits.maxTypeCharacters else {
            throw ComputerUseError.invalidArgument("text is \(text.count) characters; the per-call limit is \(ComputerUseSafety.Limits.maxTypeCharacters). Split long input across calls.")
        }
        for character in text {
            try ComputerUseService.checkCancellation()
            if character == "\n" || character == "\r" {
                try pressKey(named: "return")
            } else if character == "\t" {
                try pressKey(named: "tab")
            } else {
                try typeCharacter(character)
            }
        }
    }

    private static func typeCharacter(_ character: Character) throws {
        let units = Array(String(character).utf16)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw ComputerUseError.executionFailed("Could not create keyboard events for typing.")
        }
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// Presses one named key (down + up).
    public static func pressKey(named rawName: String) throws {
        guard let name = normalizedKeyName(rawName), let code = keycodes[name] else {
            throw ComputerUseError.invalidArgument("Unknown key '\(rawName)'. Supported keys include: return, escape, tab, delete, forwarddelete, space, arrows (left/right/up/down), home, end, pageup, pagedown, f1–f17, and single letters/digits.")
        }
        try postKey(virtualKey: code, keyDown: true)
        try postKey(virtualKey: code, keyDown: false)
    }

    /// Executes a shortcut spec like "command+shift+p".
    public static func shortcut(_ spec: String) throws {
        guard let parsed = parseShortcut(spec), let code = keycodes[parsed.key] else {
            throw ComputerUseError.invalidArgument("Invalid shortcut '\(spec)'. Use the form modifier+modifier+key with modifiers command/shift/option/control/fn and a supported key, e.g. \"command+shift+p\".")
        }
        let eventFlags = flags(for: parsed.modifiers)
        try postKey(virtualKey: code, keyDown: true, flags: eventFlags)
        try postKey(virtualKey: code, keyDown: false, flags: eventFlags)
    }
    #else
    public static func type(_ text: String) async throws { throw ComputerUseError.platformUnavailable }
    public static func pressKey(named rawName: String) throws { throw ComputerUseError.platformUnavailable }
    public static func shortcut(_ spec: String) throws { throw ComputerUseError.platformUnavailable }
    #endif
}
