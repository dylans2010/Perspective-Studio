import Foundation
#if os(macOS)
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
#endif

// MARK: - Computer Use Coordinate System
//
// Computer Use has exactly ONE input coordinate system, used by every
// mouse, keyboard-focus, accessibility and verification tool:
//
//   GLOBAL POINTS — CoreGraphics global display coordinates.
//   Origin (0, 0) is the TOP-LEFT corner of the primary display,
//   x grows right, y grows down, units are logical points (not pixels).
//   Secondary displays may have negative or offset origins.
//
// This is the coordinate system CGEvent, CGDisplayBounds and the
// Accessibility API (kAXPositionAttribute / kAXSizeAttribute) all use,
// so values pass between those APIs without conversion. It is NOT the
// AppKit/NSScreen system (origin bottom-left of the primary display,
// y up) and it is NOT screenshot pixels.
//
// Screenshot pixels convert through a display's scale factor:
//   pixel = (globalPoint - displayBounds.origin) * scaleFactor
//   globalPoint = displayBounds.origin + pixel / scaleFactor
// where scaleFactor = pixelWidth / boundsWidth (2 on Retina, 1 otherwise).
// When a screenshot is downscaled before being returned to a model, the
// tool result states the returned image size separately; the model must
// divide image pixels by (returnedImageWidth / displayBoundsWidth)
// before treating them as global points. The helpers below centralise
// all of this — no other file in Computer Use does coordinate maths.

/// An axis-aligned rectangle in global points (top-left origin).
public struct ComputerUseRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    public func contains(pointX: Double, pointY: Double) -> Bool {
        pointX >= x && pointX < maxX && pointY >= y && pointY < maxY
    }

    public var summary: String {
        "x=\(Self.format(x)) y=\(Self.format(y)) w=\(Self.format(width)) h=\(Self.format(height))"
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// A 2D size in points or pixels, depending on context (documented at
/// each use site).
public struct ComputerUseSize: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A single physical display, described in the global-points system.
public struct ComputerUseDisplayInfo: Codable, Sendable, Equatable {
    /// CGDirectDisplayID.
    public var id: UInt32
    public var name: String
    /// Bounds in global points (top-left origin, may be offset/negative).
    public var bounds: ComputerUseRect
    /// Native pixel resolution of the display mode.
    public var pixelSize: ComputerUseSize
    public var isMain: Bool

    public init(id: UInt32, name: String, bounds: ComputerUseRect, pixelSize: ComputerUseSize, isMain: Bool) {
        self.id = id
        self.name = name
        self.bounds = bounds
        self.pixelSize = pixelSize
        self.isMain = isMain
    }

    /// Pixels per point (2 on Retina, 1 on non-Retina). Falls back to 1
    /// when the pixel size is unknown so conversions stay identity-safe.
    public var scaleFactor: Double {
        guard bounds.width > 0, pixelSize.width > 0 else { return 1 }
        return pixelSize.width / bounds.width
    }

    public var summary: String {
        let main = isMain ? " (main)" : ""
        return "Display \(id) \"\(name)\"\(main): bounds \(bounds.summary), "
            + "pixels \(Int(pixelSize.width))x\(Int(pixelSize.height)), scale \(scaleFactor)x"
    }
}

/// Centralised coordinate conversion and validation. Pure functions over
/// `ComputerUseDisplayInfo` so they are unit-testable without hardware.
public enum ComputerUseCoordinates {

    /// True when the point (global points) lies on any known display.
    public static func isValid(pointX: Double, pointY: Double, displays: [ComputerUseDisplayInfo]) -> Bool {
        displays.contains { $0.bounds.contains(pointX: pointX, pointY: pointY) }
    }

    /// The display containing a global point, if any.
    public static func display(containingPointX x: Double, pointY y: Double, in displays: [ComputerUseDisplayInfo]) -> ComputerUseDisplayInfo? {
        displays.first { $0.bounds.contains(pointX: x, pointY: y) }
    }

    /// Global point -> pixel position inside a screenshot of `display`
    /// rendered at `imageSize` pixels (which may be a downscale of the
    /// display's native pixel size).
    public static func screenshotPixel(
        globalPointX x: Double,
        globalPointY y: Double,
        display: ComputerUseDisplayInfo,
        imageWidth: Double,
        imageHeight: Double
    ) -> (x: Double, y: Double) {
        guard display.bounds.width > 0, display.bounds.height > 0 else { return (0, 0) }
        let fx = (x - display.bounds.x) / display.bounds.width
        let fy = (y - display.bounds.y) / display.bounds.height
        return (fx * imageWidth, fy * imageHeight)
    }

    /// Pixel position inside a screenshot -> global point. This is the
    /// conversion a model performs (via these numbers in the tool
    /// result) when it picks a target from a screenshot.
    public static func globalPoint(
        screenshotPixelX px: Double,
        screenshotPixelY py: Double,
        display: ComputerUseDisplayInfo,
        imageWidth: Double,
        imageHeight: Double
    ) -> (x: Double, y: Double) {
        guard imageWidth > 0, imageHeight > 0 else { return (display.bounds.x, display.bounds.y) }
        let fx = px / imageWidth
        let fy = py / imageHeight
        return (display.bounds.x + fx * display.bounds.width,
                display.bounds.y + fy * display.bounds.height)
    }

    #if os(macOS)
    /// The real displays attached to this Mac, via CGDisplayBounds
    /// (global points) + the active display mode (pixels) + NSScreen
    /// names where available.
    public static func currentDisplays() -> [ComputerUseDisplayInfo] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return []
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &ids, &displayCount) == .success else {
            return []
        }
        let mainID = CGMainDisplayID()
        return ids.map { id in
            let bounds = CGDisplayBounds(id)
            var pixelWidth = Double(CGDisplayPixelsWide(id))
            var pixelHeight = Double(CGDisplayPixelsHigh(id))
            if let mode = CGDisplayCopyDisplayMode(id) {
                pixelWidth = Double(mode.pixelWidth)
                pixelHeight = Double(mode.pixelHeight)
            }
            return ComputerUseDisplayInfo(
                id: id,
                name: displayName(for: id),
                bounds: ComputerUseRect(
                    x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                    width: Double(bounds.size.width), height: Double(bounds.size.height)
                ),
                pixelSize: ComputerUseSize(width: pixelWidth, height: pixelHeight),
                isMain: id == mainID
            )
        }
    }

    private static func displayName(for id: CGDirectDisplayID) -> String {
        #if canImport(AppKit)
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               number.uint32Value == id {
                return screen.localizedName
            }
        }
        #endif
        return id == CGMainDisplayID() ? "Built-in / Main Display" : "Display \(id)"
    }
    #else
    public static func currentDisplays() -> [ComputerUseDisplayInfo] { [] }
    #endif
}
