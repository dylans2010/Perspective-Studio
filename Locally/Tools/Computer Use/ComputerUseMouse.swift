import Foundation
#if os(macOS)
import CoreGraphics
#endif

/// Mouse input via CGEvent, posted to the HID event tap.
///
/// Every entry point validates its target against the live display
/// bounds first: a coordinate that is not on any display is a stale
/// or hallucinated target, and the correct behaviour is a structured
/// error telling the model to re-observe — never a click into nowhere.
public enum ComputerUseMouse {

    public enum Button: String, Sendable {
        case left
        case right
    }

    #if os(macOS)
    private static func validatedPoint(x: Double, y: Double) throws -> CGPoint {
        let displays = ComputerUseCoordinates.currentDisplays()
        guard ComputerUseCoordinates.isValid(pointX: x, pointY: y, displays: displays) else {
            throw ComputerUseError.staleOrInvalidTarget(
                "point (\(x), \(y)) is outside every display. Displays: \(displays.map { $0.summary }.joined(separator: " | "))"
            )
        }
        return CGPoint(x: x, y: y)
    }

    private static func post(_ event: CGEvent) throws {
        event.post(tap: .cghidEventTap)
    }

    private static func makeMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ComputerUseError.executionFailed("Could not create a CGEvent of type \(type.rawValue).")
        }
        return event
    }

    /// Moves the pointer (also how hover states and menus are revealed).
    public static func move(toX x: Double, y: Double) throws {
        let point = try validatedPoint(x: x, y: y)
        try post(makeMouseEvent(type: .mouseMoved, point: point, button: .left))
    }

    /// Clicks at a point. `clickCount` 2 performs a real double-click
    /// (down/up pairs with an increasing clickState, like hardware).
    public static func click(atX x: Double, y: Double, button: Button = .left, clickCount: Int = 1) throws {
        let point = try validatedPoint(x: x, y: y)
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        let count = min(max(clickCount, 1), 3)
        for index in 1...count {
            try ComputerUseService.checkCancellation()
            let down = try makeMouseEvent(type: downType, point: point, button: cgButton)
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            try post(down)
            let up = try makeMouseEvent(type: upType, point: point, button: cgButton)
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            try post(up)
        }
    }

    /// Scrolls over a point. Positive `deltaY` scrolls down (content
    /// moves up, the standard "natural" direction expressed as wheel
    /// movement away from the user is negative in CGEvent, so this
    /// layer takes the human direction and negates internally).
    public static func scroll(atX x: Double, y: Double, deltaX: Double, deltaY: Double) throws {
        let point = try validatedPoint(x: x, y: y)
        // Move first so the scroll lands on the intended window.
        try move(toX: x, y: y)
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(-deltaY.rounded()),
            wheel2: Int32(-deltaX.rounded()),
            wheel3: 0
        ) else {
            throw ComputerUseError.executionFailed("Could not create a scroll CGEvent.")
        }
        event.location = point
        try post(event)
    }

    /// Drags from one point to another with interpolated movement so
    /// apps that track drag gestures (sliders, canvas, Finder) see a
    /// realistic path instead of a teleport.
    public static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationSeconds: Double = 0.5) async throws {
        let start = try validatedPoint(x: fromX, y: fromY)
        let end = try validatedPoint(x: toX, y: toY)
        try post(makeMouseEvent(type: .leftMouseDown, point: start, button: .left))
        let steps = 12
        for step in 1...steps {
            try ComputerUseService.checkCancellation()
            let t = Double(step) / Double(steps)
            let intermediate = CGPoint(
                x: start.x + (end.x - start.x) * t,
                y: start.y + (end.y - start.y) * t
            )
            try post(makeMouseEvent(type: .leftMouseDragged, point: intermediate, button: .left))
            if step < steps, durationSeconds > 0 {
                try await Task.sleep(for: .seconds(durationSeconds / Double(steps)))
            }
        }
        try post(makeMouseEvent(type: .leftMouseUp, point: end, button: .left))
    }
    #else
    public static func move(toX x: Double, y: Double) throws { throw ComputerUseError.platformUnavailable }
    public static func click(atX x: Double, y: Double, button: Button = .left, clickCount: Int = 1) throws { throw ComputerUseError.platformUnavailable }
    public static func scroll(atX x: Double, y: Double, deltaX: Double, deltaY: Double) throws { throw ComputerUseError.platformUnavailable }
    public static func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, durationSeconds: Double = 0.5) async throws { throw ComputerUseError.platformUnavailable }
    #endif
}
