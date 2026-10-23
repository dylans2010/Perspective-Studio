import Foundation

/// Captures a real screenshot with ScreenCaptureKit and returns it
/// (base64 PNG in `data.imageBase64`) together with the exact mapping
/// between image pixels and global points used by the input tools.
public struct ComputerScreenshotTool: AssistTool {
    public let id = "computer_screenshot"
    public let name = "Take Screenshot"
    public let description = "Captures a real screenshot of a display (default: main display) using ScreenCaptureKit. Returns a base64 PNG plus display bounds and scale so image pixels can be converted to the global-point coordinates the mouse tools use. Optional region (global points) captures only part of the display. If your model cannot view images, use computer_read_screen_text (OCR) and computer_get_accessibility_tree instead — do not claim to have seen a screenshot you cannot view."

    public var parametersSchema: JSONSchema {
        JSONSchema(
            type: "object",
            description: description,
            properties: [
                "displayId": JSONSchema(type: "integer", description: "Optional CGDirectDisplayID from computer_get_screen_info. Default: the main display."),
                "region": JSONSchema(
                    type: "object",
                    description: "Optional region in global points to capture instead of the whole display.",
                    properties: [
                        "x": JSONSchema(type: "number", description: "Left edge, global points."),
                        "y": JSONSchema(type: "number", description: "Top edge, global points."),
                        "width": JSONSchema(type: "number", description: "Width in points."),
                        "height": JSONSchema(type: "number", description: "Height in points.")
                    ]
                )
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
            var region: ComputerUseRect?
            if let regionDict = ComputerUseArguments.object(input, "region"),
               let x = ComputerUseArguments.double(regionDict, "x"),
               let y = ComputerUseArguments.double(regionDict, "y"),
               let width = ComputerUseArguments.double(regionDict, "width"),
               let height = ComputerUseArguments.double(regionDict, "height") {
                region = ComputerUseRect(x: x, y: y, width: width, height: height)
            }
            let capture = try await ComputerUseService.withTimeout {
                try await ComputerUseScreen.capture(displayID: displayID, region: region)
            }
            let d = capture.display
            let output = """
            Screenshot captured from \(d.summary).
            Returned image: \(capture.imageWidth)x\(capture.imageHeight) pixels (\(capture.mimeType))\(capture.wasDownscaled ? ", downscaled from native resolution to bound context" : "").
            Captured region (global points): \(capture.capturedRegion.summary).
            Coordinate mapping: to click something at image pixel (px, py), convert to global points with \
            globalX = \(ComputerUseRect.format(capture.capturedRegion.x)) + px / \(capture.imageWidth) * \(ComputerUseRect.format(capture.capturedRegion.width)), \
            globalY = \(ComputerUseRect.format(capture.capturedRegion.y)) + py / \(capture.imageHeight) * \(ComputerUseRect.format(capture.capturedRegion.height)). \
            Mouse and accessibility tools take global points. Do not reuse these coordinates after the layout changes — observe again.
            The image data is in data.imageBase64. If you cannot view images, use computer_read_screen_text and computer_get_accessibility_tree instead.
            """
            return ComputerUseService.success(output, data: [
                "imageBase64": capture.base64,
                "mimeType": capture.mimeType,
                "imageWidth": String(capture.imageWidth),
                "imageHeight": String(capture.imageHeight),
                "displayId": String(d.id),
                "displayBoundsX": String(d.bounds.x),
                "displayBoundsY": String(d.bounds.y),
                "displayBoundsWidth": String(d.bounds.width),
                "displayBoundsHeight": String(d.bounds.height),
                "scaleFactor": String(d.scaleFactor),
                "wasDownscaled": capture.wasDownscaled ? "true" : "false"
            ], suggestedNextActions: ["Ground any click in these coordinates or an accessibility element, then verify with computer_verify_state."])
        } catch {
            return .computerUseFailure(error)
        }
    }
}
