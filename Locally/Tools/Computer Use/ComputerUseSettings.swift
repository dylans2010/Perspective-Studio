import Foundation

/// The Computer Use master switch (Settings > Computer Use).
///
/// Computer Use is **off by default**: a feature that can see the
/// screen and drive other apps must be opted into by the user, in
/// Settings, before any tool will act. The switch is a plain
/// UserDefaults bool so the Settings toggle (`@AppStorage`) and the
/// tool layer read and write exactly the same value.
///
/// Enforcement lives in `ComputerUseService.gate`, which every
/// Computer Use tool calls before doing anything — except
/// `computer_get_permissions`, which stays available while disabled
/// so the model can still report status and explain how to turn the
/// feature on. Revoking the switch mid-task stops the *next* tool
/// call; already-dispatched actions are unaffected (and were reported
/// when they happened).
public enum ComputerUseSettings {

    /// UserDefaults key shared with the Settings `@AppStorage` toggle.
    public static let enabledKey = "computerUseEnabled"

    /// True only when the user has explicitly turned Computer Use on.
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    /// The failure a gated tool must return while the switch is off.
    public static var disabledFailure: AssistToolResult {
        ComputerUseError.featureDisabled.result
    }
}
