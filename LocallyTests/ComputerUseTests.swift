import XCTest
@testable import Locally

/// Tests for the Computer Use suite.
///
/// The pure layers (coordinate maths, OCR box conversion, shortcut
/// parsing, argument coercion, safety policy, schemas) are tested
/// exhaustively here because they are where real-world Computer Use
/// bugs live. Live macOS behaviour (a granted Accessibility prompt, a
/// real ScreenCaptureKit capture, CGEvent delivery into another app)
/// cannot be proven by unit tests and is covered by the manual
/// end-to-end checklist on Dylan's Mac — these tests never fake it.
final class ComputerUseTests: XCTestCase {

    // MARK: - Fixtures

    private var retinaMain: ComputerUseDisplayInfo {
        ComputerUseDisplayInfo(
            id: 1, name: "Main Retina",
            bounds: ComputerUseRect(x: 0, y: 0, width: 1512, height: 982),
            pixelSize: ComputerUseSize(width: 3024, height: 1964),
            isMain: true
        )
    }

    private var externalLeft: ComputerUseDisplayInfo {
        // A non-Retina display placed left of the main display:
        // negative origin, scale 1.
        ComputerUseDisplayInfo(
            id: 2, name: "External",
            bounds: ComputerUseRect(x: -1920, y: 120, width: 1920, height: 1080),
            pixelSize: ComputerUseSize(width: 1920, height: 1080),
            isMain: false
        )
    }

    // MARK: - Coordinates

    func testScaleFactorRetinaAndNonRetina() {
        XCTAssertEqual(retinaMain.scaleFactor, 2, accuracy: 0.0001)
        XCTAssertEqual(externalLeft.scaleFactor, 1, accuracy: 0.0001)
    }

    func testScreenshotConversionRoundTripRetina() {
        // A point in the middle of the main display, via a native-size image.
        let pixel = ComputerUseCoordinates.screenshotPixel(
            globalPointX: 756, globalPointY: 491,
            display: retinaMain, imageWidth: 3024, imageHeight: 1964
        )
        XCTAssertEqual(pixel.x, 1512, accuracy: 0.001)
        XCTAssertEqual(pixel.y, 982, accuracy: 0.001)
        let back = ComputerUseCoordinates.globalPoint(
            screenshotPixelX: pixel.x, screenshotPixelY: pixel.y,
            display: retinaMain, imageWidth: 3024, imageHeight: 1964
        )
        XCTAssertEqual(back.x, 756, accuracy: 0.001)
        XCTAssertEqual(back.y, 491, accuracy: 0.001)
    }

    func testScreenshotConversionWithDownscaledImageAndOffsetDisplay() {
        // Downscaled screenshot (half size) of the offset external display.
        // Its top-left corner is global (-1920, 120) but image pixel (0,0).
        let topLeft = ComputerUseCoordinates.globalPoint(
            screenshotPixelX: 0, screenshotPixelY: 0,
            display: externalLeft, imageWidth: 960, imageHeight: 540
        )
        XCTAssertEqual(topLeft.x, -1920, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 120, accuracy: 0.001)
        let centre = ComputerUseCoordinates.globalPoint(
            screenshotPixelX: 480, screenshotPixelY: 270,
            display: externalLeft, imageWidth: 960, imageHeight: 540
        )
        XCTAssertEqual(centre.x, -960, accuracy: 0.001)
        XCTAssertEqual(centre.y, 660, accuracy: 0.001)
    }

    func testBoundsValidationAcrossDisplays() {
        let displays = [retinaMain, externalLeft]
        XCTAssertTrue(ComputerUseCoordinates.isValid(pointX: 0, pointY: 0, displays: displays))
        XCTAssertTrue(ComputerUseCoordinates.isValid(pointX: -100, pointY: 200, displays: displays))
        XCTAssertFalse(ComputerUseCoordinates.isValid(pointX: 5000, pointY: 100, displays: displays))
        XCTAssertFalse(ComputerUseCoordinates.isValid(pointX: 100, pointY: -50, displays: displays))
        XCTAssertEqual(
            ComputerUseCoordinates.display(containingPointX: -100, pointY: 200, in: displays)?.id,
            2
        )
    }

    func testOCRFrameConversionFlipsY() {
        // Vision box: left half, top quarter of the screen. In Vision's
        // bottom-left normalised space the top quarter is y 0.75..1.0.
        let frame = ComputerUseTextBlock.frame(
            normalizedX: 0, normalizedY: 0.75, normalizedWidth: 0.5, normalizedHeight: 0.25,
            region: ComputerUseRect(x: 0, y: 0, width: 1000, height: 800)
        )
        XCTAssertEqual(frame.x, 0, accuracy: 0.001)
        XCTAssertEqual(frame.y, 0, accuracy: 0.001)
        XCTAssertEqual(frame.width, 500, accuracy: 0.001)
        XCTAssertEqual(frame.height, 200, accuracy: 0.001)
    }

    // MARK: - Keyboard parsing

    func testParseShortcut() {
        let parsed = ComputerUseKeyboard.parseShortcut("command+shift+p")
        XCTAssertEqual(parsed?.key, "p")
        XCTAssertEqual(parsed?.modifiers, ["command", "shift"])

        let aliased = ComputerUseKeyboard.parseShortcut("cmd+alt+tab")
        XCTAssertEqual(aliased?.key, "tab")
        XCTAssertEqual(aliased?.modifiers, ["command", "option"])

        XCTAssertNil(ComputerUseKeyboard.parseShortcut("command+shift")) // modifier as key
        XCTAssertNil(ComputerUseKeyboard.parseShortcut("hyper+p"))       // unknown modifier
        XCTAssertNil(ComputerUseKeyboard.parseShortcut("command+banana")) // unknown key
        XCTAssertNil(ComputerUseKeyboard.parseShortcut(""))
    }

    func testNormalizedKeyNames() {
        XCTAssertEqual(ComputerUseKeyboard.normalizedKeyName("Return"), "return")
        XCTAssertEqual(ComputerUseKeyboard.normalizedKeyName("ESC"), "esc")
        XCTAssertEqual(ComputerUseKeyboard.normalizedKeyName("→"), "right")
        XCTAssertNil(ComputerUseKeyboard.normalizedKeyName("banana"))
    }

    // MARK: - Argument coercion

    func testArgumentCoercionFromMixedTypes() {
        let input: [String: Any] = [
            "x": "42.5",
            "count": 3,
            "flag": "true",
            "point": "{\"x\": 10, \"y\": 20}"
        ]
        XCTAssertEqual(ComputerUseArguments.double(input, "x") ?? 0, 42.5, accuracy: 0.001)
        XCTAssertEqual(ComputerUseArguments.int(input, "count"), 3)
        XCTAssertEqual(ComputerUseArguments.bool(input, "flag"), true)
        let point = ComputerUseArguments.point(input)
        XCTAssertEqual(point?.x ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(point?.y ?? 0, 20, accuracy: 0.001)
        XCTAssertNil(ComputerUseArguments.double(input, "missing"))
    }

    // MARK: - Safety policy

    func testSafetyRefusesClosingLocallyAndForceQuit() {
        let closeSelf = ComputerUseSafety.validate(
            toolID: "computer_close_application",
            input: ["bundleId": ComputerUseSafety.locallyBundleIdentifier]
        )
        XCTAssertNotNil(closeSelf)

        let force = ComputerUseSafety.validate(
            toolID: "computer_close_application",
            input: ["bundleId": "com.apple.TextEdit", "force": true]
        )
        XCTAssertNotNil(force)

        let ordinary = ComputerUseSafety.validate(
            toolID: "computer_close_application",
            input: ["bundleId": "com.apple.TextEdit"]
        )
        XCTAssertNil(ordinary)
    }

    func testRedactedTextSummaryNeverContainsText() {
        let summary = ComputerUseSafety.redactedTextSummary("hunter2-secret")
        XCTAssertFalse(summary.contains("hunter2"))
        XCTAssertTrue(summary.contains("14"))
    }

    // MARK: - Registry

    @MainActor
    func testAllComputerUseToolsRegisteredExactlyOnce() {
        let registry = ToolsRegistry.shared
        let computerTools = registry.allTools.filter { $0.id.hasPrefix("computer_") }
        XCTAssertEqual(
            Set(computerTools.map { $0.id }),
            Set(ComputerUseToolRegistry.toolIDs),
            "Registered computer_* tools must match ComputerUseToolRegistry.toolIDs exactly"
        )
        XCTAssertEqual(
            computerTools.count,
            ComputerUseToolRegistry.toolIDs.count,
            "Duplicate registration would inflate the count"
        )
    }

    @MainActor
    func testReRegistrationDoesNotDuplicate() {
        let registry = ToolsRegistry()
        let before = registry.allTools.filter { $0.id.hasPrefix("computer_") }.count
        ComputerUseToolRegistry.registerAll(into: registry)
        let after = registry.allTools.filter { $0.id.hasPrefix("computer_") }.count
        XCTAssertEqual(before, after)
    }

    @MainActor
    func testComputerUseSchemasAreComplete() {
        for tool in ComputerUseToolRegistry.allTools {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.id) has no description")
            XCTAssertEqual(tool.capability, .computerUse, "\(tool.id) must use the Computer Use capability")
        }
        let byId = Dictionary(uniqueKeysWithValues: ComputerUseToolRegistry.allTools.map { ($0.id, $0) })
        XCTAssertEqual(Set(byId["computer_mouse_click"]?.parametersSchema.required ?? []), ["x", "y"])
        XCTAssertEqual(Set(byId["computer_keyboard_type"]?.parametersSchema.required ?? []), ["text"])
        XCTAssertEqual(Set(byId["computer_verify_state"]?.parametersSchema.required ?? []), ["condition"])
        XCTAssertEqual(Set(byId["computer_mouse_drag"]?.parametersSchema.required ?? []), ["fromX", "fromY", "toX", "toY"])
        XCTAssertNotNil(byId["computer_screenshot"]?.parametersSchema.properties?["displayId"])
        XCTAssertNotNil(byId["computer_screenshot"]?.parametersSchema.properties?["region"])
    }

    @MainActor
    func testInputToolsRequireConfirmationButObservationDoesNot() {
        let registry = ToolsRegistry.shared
        XCTAssertEqual(registry.definition(for: "computer_mouse_click")?.requiresConfirmation, true)
        XCTAssertEqual(registry.definition(for: "computer_keyboard_type")?.requiresConfirmation, true)
        XCTAssertEqual(registry.definition(for: "computer_close_application")?.requiresConfirmation, true)
        XCTAssertEqual(registry.definition(for: "computer_screenshot")?.requiresConfirmation, false)
        XCTAssertEqual(registry.definition(for: "computer_get_accessibility_tree")?.requiresConfirmation, false)
    }

    // MARK: - System Asset wiring

    @MainActor
    func testComputerUseAssetIsIndexedAndComplete() async {
        let manager = SystemAssetsManager.shared
        await manager.scanAssets()
        XCTAssertTrue(manager.availableAssets().contains { $0.id == "computer_use" })
        XCTAssertTrue(manager.generatePromptIndex().contains("computer_use"))
        let content = manager.fetchAssetContent(named: "computer_use")
        XCTAssertNotNil(content)
        for toolID in ComputerUseToolRegistry.toolIDs {
            XCTAssertTrue(
                content?.contains(toolID) == true,
                "computer_use asset must document the real tool \(toolID)"
            )
        }
    }

    // MARK: - Error mapping

    func testErrorCodesAndRecoveryHints() {
        XCTAssertEqual(ComputerUseError.permissionDenied(permission: "Accessibility", guidance: "g").code, .permissionDenied)
        XCTAssertEqual(ComputerUseError.timedOut("t").code, .timeout)
        XCTAssertEqual(ComputerUseError.cancelled.code, .cancelled)
        XCTAssertFalse(ComputerUseError.ambiguous("a", candidates: ["b"]).message.isEmpty)
        XCTAssertTrue(ComputerUseError.staleOrInvalidTarget("s").recoveryHint.localizedCaseInsensitiveContains("observation"))
    }

    // MARK: - Wait tool bounds (no live desktop needed)

    func testWaitToolRejectsUnboundedWaits() async throws {
        let context = AssistContext()
        let tooLong = try await ComputerWaitTool().execute(input: ["seconds": 120], context: context)
        XCTAssertFalse(tooLong.success)
        let missing = try await ComputerWaitTool().execute(input: [:], context: context)
        XCTAssertFalse(missing.success)
        let badCondition = try await ComputerWaitTool().execute(input: ["condition": "nonsense", "timeoutSeconds": 1], context: context)
        XCTAssertFalse(badCondition.success)
    }

    // MARK: - Live observation (this Mac only)

    @MainActor
    func testScreenInfoToolReturnsRealDisplays() async throws {
        let result = try await ComputerGetScreenInfoTool().execute(input: [:], context: AssistContext())
        XCTAssertTrue(result.success, result.output)
        XCTAssertFalse((result.data?["displays"] ?? "").isEmpty)
    }
}
