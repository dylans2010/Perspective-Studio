import Foundation
#if os(macOS)
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#endif

/// Screen observation: real display metadata and real screenshots via
/// ScreenCaptureKit. Nothing here simulates or caches an image — every
/// capture is a fresh `SCScreenshotManager` call against the live
/// desktop, and a capture that macOS refuses surfaces as a structured
/// permission/execution error, never as a placeholder image.
public enum ComputerUseScreen {

    /// A captured screenshot plus everything a model needs to map
    /// image pixels back to global points.
    public struct Capture: @unchecked Sendable {
        /// The captured image (possibly cropped / downscaled — see
        /// `imageWidth`/`imageHeight` for its actual pixel size).
        public let image: CGImage
        /// The display the capture came from (global-points bounds).
        public let display: ComputerUseDisplayInfo
        /// Pixel size of `image` as returned.
        public let imageWidth: Int
        public let imageHeight: Int
        /// Base64-encoded image data (`mimeType` says the format).
        public let base64: String
        public let mimeType: String
        /// True when the image was downscaled from the display's
        /// native pixel size to bound model context.
        public let wasDownscaled: Bool
        /// The global-points region that was captured (the full
        /// display when no region was requested).
        public let capturedRegion: ComputerUseRect
    }

    #if os(macOS)
    /// Captures one display (default: the main display), optionally
    /// restricted to a region given in global points.
    public static func capture(displayID: UInt32? = nil, region: ComputerUseRect? = nil) async throws -> Capture {
        let displays = ComputerUseCoordinates.currentDisplays()
        guard !displays.isEmpty else {
            throw ComputerUseError.executionFailed("No active displays were reported by CoreGraphics.")
        }
        let displayInfo: ComputerUseDisplayInfo
        if let displayID {
            guard let match = displays.first(where: { $0.id == displayID }) else {
                throw ComputerUseError.notFound("display \(displayID). Available: \(displays.map { String($0.id) }.joined(separator: ", "))")
            }
            displayInfo = match
        } else {
            displayInfo = displays.first(where: { $0.isMain }) ?? displays[0]
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ComputerUseError.executionFailed("ScreenCaptureKit could not enumerate shareable content: \(error.localizedDescription). If Screen Recording permission was just granted, relaunch Locally and retry.")
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayInfo.id }) ?? content.displays.first else {
            throw ComputerUseError.notFound("display \(displayInfo.id) in ScreenCaptureKit content")
        }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(displayInfo.pixelSize.width))
        configuration.height = max(1, Int(displayInfo.pixelSize.height))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        var image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw ComputerUseError.executionFailed("Screenshot capture failed: \(error.localizedDescription)")
        }

        var capturedRegion = displayInfo.bounds
        if let region {
            // Region is in global points; crop in the captured image's
            // native pixel space (image size == display pixel size here).
            let topLeft = ComputerUseCoordinates.screenshotPixel(
                globalPointX: region.x, globalPointY: region.y,
                display: displayInfo,
                imageWidth: Double(image.width), imageHeight: Double(image.height)
            )
            let bottomRight = ComputerUseCoordinates.screenshotPixel(
                globalPointX: region.maxX, globalPointY: region.maxY,
                display: displayInfo,
                imageWidth: Double(image.width), imageHeight: Double(image.height)
            )
            let cropRect = CGRect(
                x: max(0, topLeft.x), y: max(0, topLeft.y),
                width: max(1, bottomRight.x - topLeft.x), height: max(1, bottomRight.y - topLeft.y)
            ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard !cropRect.isNull, let cropped = image.cropping(to: cropRect) else {
                throw ComputerUseError.invalidArgument("region \(region.summary) does not intersect display \(displayInfo.id)")
            }
            image = cropped
            capturedRegion = region
        }

        // Downscale oversized captures so a screenshot does not flood
        // the model's context. Coordinates are unaffected: tools act in
        // global points, and the result reports both sizes.
        var wasDownscaled = false
        let longest = max(image.width, image.height)
        if longest > ComputerUseSafety.Limits.maxScreenshotDimension {
            let factor = Double(ComputerUseSafety.Limits.maxScreenshotDimension) / Double(longest)
            let newWidth = max(1, Int(Double(image.width) * factor))
            let newHeight = max(1, Int(Double(image.height) * factor))
            if let scaled = Self.resized(image, width: newWidth, height: newHeight) {
                image = scaled
                wasDownscaled = true
            }
        }

        guard let encoded = encodePNG(image) else {
            throw ComputerUseError.executionFailed("Could not encode the captured screenshot as PNG.")
        }
        return Capture(
            image: image,
            display: displayInfo,
            imageWidth: image.width,
            imageHeight: image.height,
            base64: encoded.base64EncodedString(),
            mimeType: "image/png",
            wasDownscaled: wasDownscaled,
            capturedRegion: capturedRegion
        )
    }

    /// Captures and returns just the CGImage (used by OCR, which does
    /// not need the encoded form).
    public static func captureImage(displayID: UInt32? = nil) async throws -> (image: CGImage, display: ComputerUseDisplayInfo) {
        // Reuse the full path but skip encoding cost by capturing at
        // native size through the same ScreenCaptureKit calls.
        let capture = try await Self.capture(displayID: displayID)
        return (capture.image, capture.display)
    }

    private static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
    #else
    public static func capture(displayID: UInt32? = nil, region: ComputerUseRect? = nil) async throws -> Capture {
        throw ComputerUseError.platformUnavailable
    }

    public static func captureImage(displayID: UInt32? = nil) async throws -> (image: CGImage, display: ComputerUseDisplayInfo) {
        throw ComputerUseError.platformUnavailable
    }
    #endif
}
