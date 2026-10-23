import Foundation

/// State verification: re-observes the desktop and compares it against
/// an explicit expected condition, returning evidence either way.
///
/// This is what separates "the tool ran" from "the action worked" in
/// Computer Use: after clicking, typing or launching, the agent calls
/// `computer_verify_state` (or the wait tool's condition form) and
/// gets `met: true/false` plus the observed evidence — never a claim
/// the layer cannot back with a fresh observation.
public enum ComputerUseVerification {

    public struct Outcome: Sendable {
        public var met: Bool
        public var evidence: String
        public var condition: String
    }

    /// The supported condition names (also the `condition` argument
    /// values of `computer_verify_state` / `computer_wait`).
    public static let supportedConditions = [
        "app_frontmost", "app_running", "window_exists",
        "element_exists", "text_on_screen", "element_value_contains"
    ]

    /// Evaluates one condition described by tool arguments.
    ///
    /// Expected arguments by condition:
    /// - `app_frontmost` / `app_running`: `bundleId` or `name` or `pid`
    /// - `window_exists`: `titleContains` (optional `pid`)
    /// - `element_exists`: query fields `role`, `title`, `label`,
    ///   `identifier`, `value` (optional `pid`; default frontmost app)
    /// - `element_value_contains`: the element query fields above plus
    ///   `expectedValue` — the element's value must contain it
    /// - `text_on_screen`: `text` (OCR over a fresh screenshot)
    public static func evaluate(input: [String: Any]) async throws -> Outcome {
        guard let condition = ComputerUseArguments.string(input, "condition") else {
            throw ComputerUseError.invalidArgument("Missing required argument: condition. Supported: \(supportedConditions.joined(separator: ", ")).")
        }
        switch condition {
        case "app_frontmost", "app_running":
            let bundleId = ComputerUseArguments.string(input, "bundleId", "bundle_id")
            let name = ComputerUseArguments.string(input, "name")
            let pid = ComputerUseArguments.int(input, "pid")
            if condition == "app_running" {
                if let pid {
                    let apps = await ComputerUseApplications.listRunning()
                    let found = apps.first { $0.pid == pid }
                    return Outcome(met: found != nil, evidence: found.map { "Running: \($0.summary)" } ?? "No running app with pid \(pid).", condition: condition)
                }
                if let found = try? await ComputerUseApplications.resolveRunning(bundleIdentifier: bundleId, name: name, pid: nil) {
                    return Outcome(met: true, evidence: "Running: \(found.info.summary)", condition: condition)
                }
                return Outcome(met: false, evidence: "No running application matches bundleId=\(bundleId ?? "-") name=\(name ?? "-").", condition: condition)
            }
            guard let front = await ComputerUseApplications.frontmost() else {
                return Outcome(met: false, evidence: "No frontmost application could be determined.", condition: condition)
            }
            var matches = true
            if let pid, front.pid != pid { matches = false }
            if let bundleId, front.bundleIdentifier != bundleId { matches = false }
            if let name, front.name.localizedCaseInsensitiveCompare(name) != .orderedSame { matches = false }
            if pid == nil && bundleId == nil && name == nil {
                throw ComputerUseError.invalidArgument("app_frontmost needs one of bundleId, name or pid to compare against.")
            }
            return Outcome(met: matches, evidence: "Frontmost application: \(front.summary)", condition: condition)

        case "window_exists":
            guard let titleContains = ComputerUseArguments.string(input, "titleContains", "title", "windowTitle") else {
                throw ComputerUseError.invalidArgument("window_exists needs titleContains.")
            }
            let pid = ComputerUseArguments.int(input, "pid").map { Int32($0) }
            #if os(macOS)
            let windows = await ComputerUseWindows.list(pid: pid)
            let match = windows.first { $0.title.localizedCaseInsensitiveContains(titleContains) }
            return Outcome(
                met: match != nil,
                evidence: match.map { "Found window: \($0.summary)" } ?? "No window title contains \"\(titleContains)\" among \(windows.count) observed window(s).",
                condition: condition
            )
            #else
            throw ComputerUseError.platformUnavailable
            #endif

        case "element_exists", "element_value_contains":
            #if os(macOS)
            let pid = try await resolvedPID(input)
            let query = ComputerUseAccessibility.Query(
                role: ComputerUseArguments.string(input, "role"),
                title: ComputerUseArguments.string(input, "title"),
                label: ComputerUseArguments.string(input, "label"),
                identifier: ComputerUseArguments.string(input, "identifier"),
                value: ComputerUseArguments.string(input, "value")
            )
            guard !query.isEmpty else {
                throw ComputerUseError.invalidArgument("\(condition) needs at least one element query field (role, title, label, identifier or value).")
            }
            let matches = ComputerUseAccessibility.findElements(pid: pid, query: query)
            if condition == "element_exists" {
                return Outcome(
                    met: !matches.isEmpty,
                    evidence: matches.isEmpty
                        ? "No element matches the query in pid \(pid)."
                        : "Found \(matches.count) matching element(s); first: \(matches[0].snapshot.summary)",
                    condition: condition
                )
            }
            guard let expected = ComputerUseArguments.string(input, "expectedValue", "expected_value") else {
                throw ComputerUseError.invalidArgument("element_value_contains needs expectedValue.")
            }
            let hit = matches.first { ($0.snapshot.value ?? "").localizedCaseInsensitiveContains(expected) }
            return Outcome(
                met: hit != nil,
                evidence: hit.map { "Element value contains \"\(expected)\": \($0.snapshot.summary)" }
                    ?? "No matching element's value contains \"\(expected)\". Observed values: \(matches.prefix(5).map { $0.snapshot.value ?? "(none)" }.joined(separator: " | "))",
                condition: condition
            )
            #else
            throw ComputerUseError.platformUnavailable
            #endif

        case "text_on_screen":
            guard let text = ComputerUseArguments.string(input, "text") else {
                throw ComputerUseError.invalidArgument("text_on_screen needs text.")
            }
            #if os(macOS)
            if let failure = ComputerUsePermissions.failureIfMissing(.screenRecording) { return Outcome(met: false, evidence: failure.output, condition: condition) }
            let capture = try await ComputerUseScreen.capture()
            let blocks = try await ComputerUseOCR.recognize(image: capture.image, region: capture.capturedRegion)
            let hit = blocks.first { $0.text.localizedCaseInsensitiveContains(text) }
            return Outcome(
                met: hit != nil,
                evidence: hit.map { "OCR found: \($0.summary)" } ?? "OCR read \(blocks.count) text block(s); none contains \"\(text)\".",
                condition: condition
            )
            #else
            throw ComputerUseError.platformUnavailable
            #endif

        default:
            throw ComputerUseError.invalidArgument("Unknown condition \"\(condition)\". Supported: \(supportedConditions.joined(separator: ", ")).")
        }
    }

    /// pid argument, or the frontmost app's pid when omitted.
    public static func resolvedPID(_ input: [String: Any]) async throws -> Int32 {
        if let pid = ComputerUseArguments.int(input, "pid") { return Int32(pid) }
        if let bundleId = ComputerUseArguments.string(input, "bundleId", "bundle_id"),
           let resolved = try? await ComputerUseApplications.resolveRunning(bundleIdentifier: bundleId, name: nil, pid: nil) {
            return resolved.info.pid
        }
        if let name = ComputerUseArguments.string(input, "appName", "name"),
           let resolved = try? await ComputerUseApplications.resolveRunning(bundleIdentifier: nil, name: name, pid: nil) {
            return resolved.info.pid
        }
        guard let front = await ComputerUseApplications.frontmost() else {
            throw ComputerUseError.notFound("target application. Provide pid, bundleId or name — no frontmost application could be determined.")
        }
        return front.pid
    }
}
