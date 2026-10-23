import Foundation

/// Reports (and optionally requests) the macOS permissions Computer
/// Use needs: Accessibility and Screen Recording.
public struct ComputerGetPermissionsTool: AssistTool {
    public let id = "computer_get_permissions"
    public let name = "Computer Permissions"
    public let description = "Reports whether Locally currently has the Accessibility and Screen Recording permissions Computer Use needs. Optional action: \"request\" triggers the system permission prompt, \"open_settings\" opens the exact System Settings privacy pane (requires argument permission: \"accessibility\" or \"screen_recording\")."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "action": JSONSchema(type: "string", description: "Optional: \"check\" (default), \"request\" or \"open_settings\".", enumValues: ["check", "request", "open_settings"]),
                "permission": JSONSchema(type: "string", description: "For action request/open_settings: which permission — \"accessibility\" or \"screen_recording\". Omit with \"request\" to request both.", enumValues: ["accessibility", "screen_recording"])
            ],
            required: []
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .safeRead }
    public var requiredPermission: ToolPermissionRequirement { .none }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        let action = ComputerUseArguments.string(input, "action") ?? "check"
        let permissionName = ComputerUseArguments.string(input, "permission")
        let kinds: [ComputerUsePermissionKind]
        switch permissionName {
        case "accessibility": kinds = [.accessibility]
        case "screen_recording", "screenRecording": kinds = [.screenRecording]
        case nil: kinds = ComputerUsePermissionKind.allCases
        default:
            return .failure("Unknown permission '\(permissionName ?? "")'. Use \"accessibility\" or \"screen_recording\".", code: .invalidInput)
        }

        var notes: [String] = []
        switch action {
        case "check":
            break
        case "request":
            for kind in kinds {
                let granted = ComputerUsePermissions.request(kind)
                notes.append("Requested \(kind.rawValue): \(granted ? "now granted" : "not granted yet — the user may need to enable Locally in System Settings and return; re-check with this tool instead of looping requests.")")
            }
        case "open_settings":
            guard kinds.count == 1, let kind = kinds.first else {
                return .failure("action \"open_settings\" requires the permission argument (\"accessibility\" or \"screen_recording\").", code: .invalidInput)
            }
            await MainActor.run { ComputerUsePermissions.openSettings(for: kind) }
            notes.append("Opened System Settings at the \(kind.rawValue) pane. Ask the user to enable Locally there, then re-check with this tool.")
        default:
            return .failure("Unknown action '\(action)'. Use \"check\", \"request\" or \"open_settings\".", code: .invalidInput)
        }

        let statuses = ComputerUsePermissions.allStatuses()
        let lines = statuses.map { $0.summary }
        var data: [String: String] = [:]
        for status in statuses {
            data[status.kind == .accessibility ? "accessibility" : "screenRecording"] = status.state.rawValue
        }
        let output = (notes + lines).joined(separator: "\n")
        return ComputerUseService.success(output, data: data)
        #endif
    }
}
