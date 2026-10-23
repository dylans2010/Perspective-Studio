import Foundation
#if os(macOS)
import ApplicationServices
import CoreGraphics
#if canImport(AppKit)
import AppKit
#endif
#endif

/// One window, as observed through the Accessibility API (enriched
/// with its CGWindow id when CoreGraphics can match it).
public struct ComputerUseWindowInfo: Codable, Sendable {
    public var pid: Int32
    public var appName: String
    public var title: String
    public var bounds: ComputerUseRect
    public var isMinimized: Bool
    public var isMain: Bool
    /// CGWindowID, when it could be matched by owner + bounds.
    public var windowID: UInt32?
    /// Index within the owning app's AX window list — the stable way
    /// to re-address this exact window in follow-up calls.
    public var indexInApp: Int

    public var summary: String {
        var parts = ["\"\(title.isEmpty ? "(untitled)" : title)\" — \(appName) (pid \(pid), window \(indexInApp))"]
        parts.append("bounds[\(bounds.summary)]")
        if isMinimized { parts.append("minimized") }
        if isMain { parts.append("main") }
        if let windowID { parts.append("cgWindowID=\(windowID)") }
        return parts.joined(separator: " ")
    }

    public var jsonObject: [String: Any] {
        var dict: [String: Any] = [
            "pid": Int(pid),
            "appName": appName,
            "title": title,
            "bounds": ["x": bounds.x, "y": bounds.y, "width": bounds.width, "height": bounds.height],
            "isMinimized": isMinimized,
            "isMain": isMain,
            "indexInApp": indexInApp
        ]
        if let windowID { dict["windowID"] = Int(windowID) }
        return dict
    }
}

/// Window management via the Accessibility API.
///
/// Windows are addressed by owning app (pid) plus either their index
/// in that app's AX window list or a unique title match — the same
/// identity `computer_list_windows` reports. Move/resize/minimise are
/// AX attribute writes; when an app refuses them (not settable, AX
/// error) the failure is reported with the real AXError, never hidden.
public enum ComputerUseWindows {

    #if os(macOS)
    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String) ?? ""
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        (attribute(element, name) as? NSNumber)?.boolValue ?? false
    }

    private static func frame(of element: AXUIElement) -> ComputerUseRect? {
        guard let posRef = attribute(element, kAXPositionAttribute as String),
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = attribute(element, kAXSizeAttribute as String),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return ComputerUseRect(x: Double(point.x), y: Double(point.y), width: Double(size.width), height: Double(size.height))
    }

    private static func appName(for pid: Int32) -> String {
        #if canImport(AppKit)
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        #else
        return "pid \(pid)"
        #endif
    }

    /// CGWindow entries used only to enrich AX windows with an id.
    private static func cgWindows() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return list
    }

    private static func cgWindowID(pid: Int32, bounds: ComputerUseRect, in entries: [[String: Any]]) -> UInt32? {
        for entry in entries {
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber, owner.int32Value == pid,
                  let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? NSNumber, let y = boundsDict["Y"] as? NSNumber,
                  let w = boundsDict["Width"] as? NSNumber, let h = boundsDict["Height"] as? NSNumber else { continue }
            if abs(x.doubleValue - bounds.x) <= 1, abs(y.doubleValue - bounds.y) <= 1,
               abs(w.doubleValue - bounds.width) <= 1, abs(h.doubleValue - bounds.height) <= 1 {
                return number.uint32Value
            }
        }
        return nil
    }

    private static func windowElements(pid: Int32) -> [AXUIElement] {
        let app = ComputerUseAccessibility.applicationElement(pid: pid)
        guard let windows = attribute(app, kAXWindowsAttribute as String) as? [AXUIElement] else { return [] }
        return windows
    }

    private static func info(for element: AXUIElement, pid: Int32, index: Int, cgEntries: [[String: Any]]) -> ComputerUseWindowInfo? {
        guard let bounds = frame(of: element) else { return nil }
        return ComputerUseWindowInfo(
            pid: pid,
            appName: appName(for: pid),
            title: stringAttribute(element, kAXTitleAttribute as String),
            bounds: bounds,
            isMinimized: boolAttribute(element, kAXMinimizedAttribute as String),
            isMain: boolAttribute(element, kAXMainAttribute as String),
            windowID: cgWindowID(pid: pid, bounds: bounds, in: cgEntries),
            indexInApp: index
        )
    }

    /// Lists windows. With a pid: that app's windows. Without: every
    /// regular app's windows (bounded to the frontmost 12 apps to keep
    /// the result model-sized).
    public static func list(pid: Int32?) async -> [ComputerUseWindowInfo] {
        let entries = cgWindows()
        var pids: [Int32] = []
        if let pid {
            pids = [pid]
        } else {
            let apps = await ComputerUseApplications.listRunning()
            pids = apps.prefix(12).map { $0.pid }
        }
        var results: [ComputerUseWindowInfo] = []
        for appPID in pids {
            for (index, element) in windowElements(pid: appPID).enumerated() {
                if let windowInfo = info(for: element, pid: appPID, index: index, cgEntries: entries) {
                    results.append(windowInfo)
                }
            }
        }
        return results
    }

    /// Resolves one window element for an operation. Selection is by
    /// index when given, else by unique title match, else — only when
    /// the app has exactly one window or a window is marked main —
    /// that window. Anything else is a structured error.
    public static func resolveWindow(pid: Int32, index: Int?, titleContains: String?) throws -> (element: AXUIElement, info: ComputerUseWindowInfo) {
        let elements = windowElements(pid: pid)
        guard !elements.isEmpty else {
            throw ComputerUseError.notFound("windows for pid \(pid). The application may have no open windows, or it may not expose them to accessibility.")
        }
        let entries = cgWindows()
        // Pair each window element with its info; `indexInApp` is the
        // element's position in the AX window list, so pairs stay
        // addressable even when an element yields no info.
        let pairs: [(Int, ComputerUseWindowInfo)] = elements.enumerated().compactMap { (i, el) in
            guard let windowInfo = info(for: el, pid: pid, index: i, cgEntries: entries) else { return nil }
            return (i, windowInfo)
        }
        guard !pairs.isEmpty else {
            throw ComputerUseError.notFound("windows with readable frames for pid \(pid).")
        }
        if let index {
            guard let pair = pairs.first(where: { $0.0 == index }) else {
                throw ComputerUseError.notFound("window index \(index) for pid \(pid). Available indexes: \(pairs.map { String($0.0) }.joined(separator: ", ")).")
            }
            return (elements[pair.0], pair.1)
        }
        if let titleContains, !titleContains.isEmpty {
            let matches = pairs.filter { $0.1.title.localizedCaseInsensitiveContains(titleContains) }
            if matches.isEmpty {
                throw ComputerUseError.notFound("window whose title contains \"\(titleContains)\" for pid \(pid). Windows: \(pairs.map { $0.1.summary }.joined(separator: " | "))")
            }
            if matches.count > 1 {
                throw ComputerUseError.ambiguous("\(matches.count) windows match \"\(titleContains)\"", candidates: matches.map { $0.1.summary })
            }
            return (elements[matches[0].0], matches[0].1)
        }
        if pairs.count == 1 { return (elements[pairs[0].0], pairs[0].1) }
        if let main = pairs.first(where: { $0.1.isMain }) { return (elements[main.0], main.1) }
        throw ComputerUseError.ambiguous(
            "pid \(pid) has \(pairs.count) windows and none is marked main; specify windowIndex or titleContains",
            candidates: pairs.map { $0.1.summary }
        )
    }

    // MARK: - Operations

    /// Raises a window and activates its app; verifies by re-reading
    /// the window's main/focused state afterwards.
    public static func focus(pid: Int32, index: Int?, titleContains: String?) async throws -> (info: ComputerUseWindowInfo, verified: Bool) {
        let resolved = try resolveWindow(pid: pid, index: index, titleContains: titleContains)
        #if canImport(AppKit)
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = app.activate(options: [.activateAllWindows])
        }
        #endif
        let raiseError = AXUIElementPerformAction(resolved.element, kAXRaiseAction as CFString)
        if raiseError != .success {
            // Some apps do not support AXRaise; activation alone may
            // still have focused the window — verification decides.
            if raiseError != .actionUnsupported && raiseError != .notImplemented {
                throw ComputerUseError.executionFailed("Raising the window failed with AXError \(raiseError.rawValue).")
            }
        }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(resolved.element, kAXMainAttribute as CFString, &settable)
        if settable.boolValue {
            AXUIElementSetAttributeValue(resolved.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        try await Task.sleep(for: .milliseconds(250))
        let after = try? resolveWindow(pid: pid, index: resolved.info.indexInApp, titleContains: nil)
        return (after?.info ?? resolved.info, after?.info.isMain ?? false)
    }

    public static func move(pid: Int32, index: Int?, titleContains: String?, toX x: Double, y: Double) throws -> ComputerUseWindowInfo {
        let resolved = try resolveWindow(pid: pid, index: index, titleContains: titleContains)
        var point = CGPoint(x: x, y: y)
        guard let value = AXValueCreate(.cgPoint, &point) else {
            throw ComputerUseError.executionFailed("Could not create an AXValue for the target position.")
        }
        let error = AXUIElementSetAttributeValue(resolved.element, kAXPositionAttribute as CFString, value)
        guard error == .success else {
            throw ComputerUseError.executionFailed("Moving the window failed with AXError \(error.rawValue). Some applications do not allow other processes to move their windows.")
        }
        let after = try? resolveWindow(pid: pid, index: resolved.info.indexInApp, titleContains: nil)
        return after?.info ?? resolved.info
    }

    public static func resize(pid: Int32, index: Int?, titleContains: String?, width: Double, height: Double) throws -> ComputerUseWindowInfo {
        guard width >= 50, height >= 50 else {
            throw ComputerUseError.invalidArgument("Window size must be at least 50x50 points (got \(Int(width))x\(Int(height))).")
        }
        let resolved = try resolveWindow(pid: pid, index: index, titleContains: titleContains)
        var size = CGSize(width: width, height: height)
        guard let value = AXValueCreate(.cgSize, &size) else {
            throw ComputerUseError.executionFailed("Could not create an AXValue for the target size.")
        }
        let error = AXUIElementSetAttributeValue(resolved.element, kAXSizeAttribute as CFString, value)
        guard error == .success else {
            throw ComputerUseError.executionFailed("Resizing the window failed with AXError \(error.rawValue). The application may enforce its own size limits or refuse external resizing.")
        }
        let after = try? resolveWindow(pid: pid, index: resolved.info.indexInApp, titleContains: nil)
        return after?.info ?? resolved.info
    }

    public static func setMinimized(_ minimized: Bool, pid: Int32, index: Int?, titleContains: String?) throws -> ComputerUseWindowInfo {
        let resolved = try resolveWindow(pid: pid, index: index, titleContains: titleContains)
        let error = AXUIElementSetAttributeValue(
            resolved.element,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
        guard error == .success else {
            throw ComputerUseError.executionFailed("\(minimized ? "Minimizing" : "Restoring") the window failed with AXError \(error.rawValue).")
        }
        let after = try? resolveWindow(pid: pid, index: resolved.info.indexInApp, titleContains: nil)
        return after?.info ?? resolved.info
    }
    #else
    public static func list(pid: Int32?) async -> [ComputerUseWindowInfo] { [] }
    #endif
}
