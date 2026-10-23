import Foundation

/// Returns real display metadata: ids, global-point bounds, native
/// pixel size and scale factor for every attached display.
public struct ComputerGetScreenInfoTool: AssistTool {
    public let id = "computer_get_screen_info"
    public let name = "Get Screen Info"
    public let description = "Returns metadata for every display: CGDirectDisplayID, name, bounds in global points (top-left origin — secondary displays may be offset or negative), native pixel size, and scale factor (2 on Retina). Use this before coordinate work on multi-display setups."

    public var parametersSchema: JSONSchema {
        JSONSchema(type: "object", description: description, properties: [:], required: [])
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .safeRead }
    public var requiredPermission: ToolPermissionRequirement { .none }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        #if !os(macOS)
        return ComputerUseError.platformUnavailable.result
        #else
        let displays = ComputerUseCoordinates.currentDisplays()
        guard !displays.isEmpty else {
            return .failure("No active displays were reported by CoreGraphics.", code: .executionFailed)
        }
        let output = displays.map { $0.summary }.joined(separator: "\n")
            + "\nAll bounds are in global points: origin at the top-left of the main display, x right, y down. Mouse/accessibility coordinates use this same system."
        let json = ComputerUseArguments.jsonString(displays.map { display in
            [
                "id": Int(display.id),
                "name": display.name,
                "isMain": display.isMain,
                "bounds": ["x": display.bounds.x, "y": display.bounds.y, "width": display.bounds.width, "height": display.bounds.height],
                "pixelWidth": display.pixelSize.width,
                "pixelHeight": display.pixelSize.height,
                "scaleFactor": display.scaleFactor
            ] as [String: Any]
        })
        return ComputerUseService.success(output, data: ["displays": json, "count": String(displays.count)])
        #endif
    }
}
