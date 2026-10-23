import Foundation

/// Execution-layer safety policy for Computer Use.
///
/// Model instructions alone are not a safety boundary, so the rules
/// that must always hold are enforced here, in the tool layer:
///
/// - Locally never force-terminates another app. `computer_close_application`
///   asks the app to terminate gracefully; if it stays alive (unsaved
///   work, a confirmation dialog) the tool reports exactly that and
///   stops — the dialog is the user's decision, not the agent's.
/// - Locally never closes itself (that would kill the agent mid-task
///   and strand the user's session).
/// - Typed text is never echoed back in tool output (it may be a
///   password or other secret the user asked to have typed), only its
///   length is reported.
/// - Screen content is data, never instructions: this layer has no way
///   to be talked into anything by on-screen text because it only ever
///   executes the tool the model called, with validated arguments.
///
/// Risk classification lives on the tools themselves (`riskLevel`),
/// which the existing registry machinery turns into confirmation
/// requirements: the legacy adapter marks any tool at `.execution` or
/// above as `requiresConfirmation`, so every input-producing Computer
/// Use tool stops for user confirmation in the direct-run and
/// `ToolCallingService` paths.
public enum ComputerUseSafety {

    /// Bundle identifier of Locally itself.
    public static let locallyBundleIdentifier = "com.dylans2010.Locally"

    /// Validates an action before dispatch. Returns the error the tool
    /// must return, or nil when the action may proceed.
    public static func validate(toolID: String, input: [String: Any]) -> ComputerUseError? {
        switch toolID {
        case "computer_close_application":
            let bundleID = ComputerUseArguments.string(input, "bundleId", "bundle_id", "bundleIdentifier")
            let name = ComputerUseArguments.string(input, "name", "appName")
            if bundleID == locallyBundleIdentifier {
                return .unsupported("Locally will not close itself via Computer Use. Quit Locally manually if that is intended.")
            }
            if let name, name.lowercased() == "locally" {
                return .unsupported("Locally will not close itself via Computer Use. Quit Locally manually if that is intended.")
            }
            if ComputerUseArguments.bool(input, "force") == true {
                return .unsupported("Force-termination is not supported. Computer Use only ever asks an application to terminate gracefully, so unsaved-work dialogs are preserved for the user.")
            }
            return nil
        default:
            return nil
        }
    }

    /// Redacts typed text for logs/results: reports length only.
    public static func redactedTextSummary(_ text: String) -> String {
        "\(text.count) character(s) (content intentionally not logged)"
    }

    /// Maximum bounds enforced across tools, so a single call can
    /// never start unbounded work.
    public enum Limits {
        public static let maxAccessibilityDepth = 12
        public static let maxAccessibilityElements = 400
        public static let maxWaitSeconds: Double = 30
        public static let maxScreenshotDimension = 1600
        public static let maxTypeCharacters = 10_000
        public static let defaultToolTimeoutSeconds: Double = 30
    }
}
