import AppKit
import Carbon.HIToolbox

extension Notification.Name {
    /// Posted by the global hotkey; `MainView` observes it and opens the
    /// Quick Chat window.
    static let locallyQuickChat = Notification.Name("locallyQuickChat")
}

/// Registers the system-wide ⇧⌘L global hotkey (feature M) while the app is
/// running, via Carbon's `RegisterEventHotKey` — the supported way to get a
/// global shortcut on macOS without accessibility permissions.
final class LocallyAppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5053_5444), id: 1) // 'PSTD'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                NotificationCenter.default.post(name: .locallyQuickChat, object: nil)
                return noErr
            },
            1,
            &eventSpec,
            nil,
            nil
        )
    }
}
