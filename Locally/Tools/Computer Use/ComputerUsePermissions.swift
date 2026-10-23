import Foundation
#if os(macOS)
import ApplicationServices
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
#endif

/// The macOS permissions Computer Use depends on.
///
/// Only two permissions are ever involved, and each maps to a real TCC
/// service with a real check API:
///
/// - Accessibility (`AXIsProcessTrusted`) — inspect and act on other
///   apps' UI via the Accessibility API, and (together with the app
///   being a trusted process) post CGEvents to other apps.
/// - Screen Recording (`CGPreflightScreenCaptureAccess`) — capture
///   screenshots with ScreenCaptureKit and read other apps' window
///   titles from CGWindowList.
///
/// Computer Use deliberately does NOT request Full Disk Access, Input
/// Monitoring or Automation/Apple Events: no implemented tool needs
/// them (app control is via NSWorkspace + Accessibility, never
/// AppleScript), and Accessibility does not imply Automation or vice
/// versa.
public enum ComputerUsePermissionKind: String, Codable, Sendable, CaseIterable {
    case accessibility = "Accessibility"
    case screenRecording = "Screen Recording"

    public var whyNeeded: String {
        switch self {
        case .accessibility:
            return "Lets Locally read other apps' accessibility trees, perform accessibility actions (press buttons, set values), move/resize their windows, and send mouse and keyboard input to them."
        case .screenRecording:
            return "Lets Locally capture screenshots of the desktop with ScreenCaptureKit so the model can see the screen, run OCR on it, and read window titles."
        }
    }

    public var settingsPaneURL: String {
        switch self {
        case .accessibility:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecording:
            return "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        }
    }
}

/// What macOS can actually tell us about a permission. macOS exposes no
/// reliable "denied forever" state for these services — a permission is
/// either currently granted or it is not — so this model has exactly
/// the states the platform can establish.
public enum ComputerUsePermissionState: String, Codable, Sendable {
    /// The check API says access is currently granted.
    case granted
    /// The check API says access is not currently granted (never asked,
    /// or revoked — macOS does not distinguish these for callers).
    case notGranted
    /// The capability cannot be checked on this platform/build.
    case unavailable

    public var label: String {
        switch self {
        case .granted: return "Granted"
        case .notGranted: return "Not granted"
        case .unavailable: return "Unavailable on this platform"
        }
    }
}

/// One permission's live status, for tools and UI.
public struct ComputerUsePermissionStatus: Codable, Sendable {
    public var kind: ComputerUsePermissionKind
    public var state: ComputerUsePermissionState
    public var detail: String

    public var summary: String {
        "\(kind.rawValue): \(state.label) — \(detail)"
    }
}

/// Central permission layer. Every Computer Use tool gates through
/// `require(_:)` (via `ComputerUseService`) so no tool can bypass the
/// check, and the UI uses the same functions to display state.
public enum ComputerUsePermissions {

    // MARK: - Live checks

    public static func state(for kind: ComputerUsePermissionKind) -> ComputerUsePermissionState {
        #if os(macOS)
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        }
        #else
        return .unavailable
        #endif
    }

    public static func isGranted(_ kind: ComputerUsePermissionKind) -> Bool {
        state(for: kind) == .granted
    }

    public static func status(for kind: ComputerUsePermissionKind) -> ComputerUsePermissionStatus {
        let current = state(for: kind)
        let detail: String
        switch (kind, current) {
        case (_, .granted):
            detail = "Locally currently has this access."
        case (_, .unavailable):
            detail = "This Mac/build cannot provide this access."
        case (.accessibility, .notGranted):
            detail = "Enable Locally in System Settings > Privacy & Security > Accessibility. \(kind.whyNeeded)"
        case (.screenRecording, .notGranted):
            detail = "Enable Locally in System Settings > Privacy & Security > Screen Recording, then relaunch Locally if capture still fails. \(kind.whyNeeded)"
        }
        return ComputerUsePermissionStatus(kind: kind, state: current, detail: detail)
    }

    public static func allStatuses() -> [ComputerUsePermissionStatus] {
        ComputerUsePermissionKind.allCases.map { status(for: $0) }
    }

    // MARK: - Requests

    /// Asks macOS to surface the system's own request flow.
    ///
    /// - Accessibility: `AXIsProcessTrustedWithOptions` with the prompt
    ///   option shows the system prompt that deep-links to Settings.
    /// - Screen Recording: `CGRequestScreenCaptureAccess` triggers the
    ///   system prompt on first use.
    ///
    /// Returns the *current* granted state after the call — the user
    /// may still need to toggle Locally in Settings and return, so a
    /// `false` here means "not granted yet", never "permanently denied".
    @discardableResult
    public static func request(_ kind: ComputerUsePermissionKind) -> Bool {
        #if os(macOS)
        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        }
        #else
        return false
        #endif
    }

    /// Opens the exact System Settings privacy pane for a permission.
    @MainActor
    public static func openSettings(for kind: ComputerUsePermissionKind) {
        #if os(macOS) && canImport(AppKit)
        if let url = URL(string: kind.settingsPaneURL) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: - Tool gating

    /// The failure a tool must return when `kind` is missing, or nil
    /// when the tool may proceed.
    public static func failureIfMissing(_ kind: ComputerUsePermissionKind) -> AssistToolResult? {
        let current = state(for: kind)
        guard current != .granted else { return nil }
        if current == .unavailable {
            return ComputerUseError.platformUnavailable.result
        }
        return ComputerUseError.permissionDenied(
            permission: kind.rawValue,
            guidance: "Run computer_get_permissions with action \"request\" or \"open_settings\" for \(kind.rawValue), or grant it manually in System Settings > Privacy & Security > \(kind.rawValue) by enabling Locally. Features needing it stay unavailable until it is granted; do not retry in a loop."
        ).result
    }
}
