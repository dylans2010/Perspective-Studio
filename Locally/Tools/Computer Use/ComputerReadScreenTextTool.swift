import Foundation

/// OCR over a fresh screenshot (Vision framework), returning text
/// blocks with global-point frames and confidence values.
public struct ComputerReadScreenTextTool: AssistTool {
    public let id = "computer_read_screen_text"
    public let name = "Read Screen Text (OCR)"
    public let description = "Captures a fresh screenshot and runs on-device OCR (Vision) over it. Returns each recognised text block with its frame in global points and a confidence value. OCR complements accessibility data — it can read rendered text but cannot tell a button from a picture of one, so prefer accessibility elements for actions when they exist."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "displayId": JSONSchema(type: "integer", description: "Optional CGDirectDisplayID. Default: the main display.")
            ],
            required: []
        )
    }

    public init() {}

    public var capability: ToolCapability { .computerUse }
    public var riskLevel: ToolRiskLevel { .safeRead }
    public var requiredPermission: ToolPermissionRequirement { .screenRecording }

    public func execute(input: [String: Any], context: AssistContext) async throws -> AssistToolResult {
        if let gate = ComputerUseService.gate(toolID: id, input: input, permissions: [.screenRecording]) {
            return gate
        }
        do {
            let displayID = ComputerUseArguments.int(input, "displayId", "display_id").map { UInt32($0) }
            let blocks = try await ComputerUseService.withTimeout {
                let capture = try await ComputerUseScreen.capture(displayID: displayID)
                return try await ComputerUseOCR.recognize(image: capture.image, region: capture.capturedRegion)
            }
            if blocks.isEmpty {
                return ComputerUseService.success("OCR found no readable text in the screenshot. The screen may be blank, graphical, or the text too small/unclear — try computer_get_accessibility_tree for structured UI data.", data: ["count": "0", "blocks": "[]"])
            }
            let output = blocks.map { $0.summary }.joined(separator: "\n")
            let json = ComputerUseArguments.jsonString(blocks.map { $0.jsonObject })
            return ComputerUseService.success(
                "OCR read \(blocks.count) text block(s) (frames are in global points):\n\(output)",
                data: ["count": String(blocks.count), "blocks": json]
            )
        } catch {
            return .computerUseFailure(error)
        }
    }
}
