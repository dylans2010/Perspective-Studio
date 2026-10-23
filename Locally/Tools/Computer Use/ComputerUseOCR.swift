import Foundation
#if os(macOS)
import CoreGraphics
import Vision
#endif

/// One recognised text block from OCR, with its frame converted into
/// global points so it can be clicked or verified like any other
/// observation.
public struct ComputerUseTextBlock: Codable, Sendable {
    public var text: String
    public var frame: ComputerUseRect
    public var confidence: Float

    public var summary: String {
        "\"\(text)\" [\(frame.summary)] center=(\(ComputerUseRect.format(frame.centerX)), \(ComputerUseRect.format(frame.centerY))) confidence=\(String(format: "%.2f", confidence))"
    }

    public var jsonObject: [String: Any] {
        [
            "text": text,
            "confidence": Double(confidence),
            "frame": ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height],
            "center": ["x": frame.centerX, "y": frame.centerY]
        ]
    }

    /// Converts a Vision normalised bounding box (origin bottom-left
    /// of the image, 0…1) for an image that covers `region` in global
    /// points into a global-points frame. Pure function — the Vision
    /// y-flip lives here, in exactly one place.
    public static func frame(
        normalizedX: Double, normalizedY: Double,
        normalizedWidth: Double, normalizedHeight: Double,
        region: ComputerUseRect
    ) -> ComputerUseRect {
        let x = region.x + normalizedX * region.width
        // Vision's y is measured up from the bottom of the image.
        let y = region.y + (1 - normalizedY - normalizedHeight) * region.height
        return ComputerUseRect(
            x: x, y: y,
            width: normalizedWidth * region.width,
            height: normalizedHeight * region.height
        )
    }
}

/// On-device OCR via the Vision framework.
///
/// OCR is a complement to — never a replacement for — accessibility
/// data: it sees text that apps render without exposing it (canvas,
/// images, video), but it cannot tell a button from a picture of one.
/// Results always carry their bounding boxes and confidence so the
/// model can judge how much to trust them.
public enum ComputerUseOCR {

    #if os(macOS)
    /// Recognises text in a captured image. `region` is the
    /// global-points area the image covers (the display bounds for a
    /// full-display capture), used to map Vision's normalised boxes
    /// into global points.
    public static func recognize(image: CGImage, region: ComputerUseRect) async throws -> [ComputerUseTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ComputerUseError.executionFailed("Vision OCR failed: \(error.localizedDescription)")
        }
        guard let observations = request.results else { return [] }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return ComputerUseTextBlock(
                text: candidate.string,
                frame: ComputerUseTextBlock.frame(
                    normalizedX: Double(box.origin.x), normalizedY: Double(box.origin.y),
                    normalizedWidth: Double(box.size.width), normalizedHeight: Double(box.size.height),
                    region: region
                ),
                confidence: candidate.confidence
            )
        }
    }
    #else
    public static func recognize(image: CGImage, region: ComputerUseRect) async throws -> [ComputerUseTextBlock] {
        throw ComputerUseError.platformUnavailable
    }
    #endif
}
