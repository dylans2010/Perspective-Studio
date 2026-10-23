import Foundation
#if os(macOS)
import ApplicationServices
#endif

/// A plain-value snapshot of one accessibility element.
///
/// AXUIElement references are not stable across tool calls (and are
/// not Sendable), so tools exchange snapshots: role/title/identifier/
/// value, state, the element's frame in global points, and the actions
/// it advertises. A later call re-resolves the live element from the
/// snapshot's identifying attributes (`ComputerUseAccessibility`),
/// which is also how staleness is detected — if nothing matches any
/// more, the lookup fails honestly instead of acting on a dead ref.
public struct ComputerUseElementSnapshot: Codable, Sendable {
    public var pid: Int32
    public var role: String
    public var subrole: String?
    public var title: String?
    /// kAXDescriptionAttribute — the accessibility label/description.
    public var label: String?
    public var identifier: String?
    public var value: String?
    public var isEnabled: Bool
    public var isFocused: Bool
    /// Frame in global points (top-left origin). Nil when the element
    /// does not expose a position/size.
    public var frame: ComputerUseRect?
    /// Accessibility actions the element advertises (e.g. AXPress).
    public var actions: [String]
    public var childCount: Int

    public var centerX: Double? { frame?.centerX }
    public var centerY: Double? { frame?.centerY }

    public var summary: String {
        var parts = ["role=\(role)"]
        if let subrole { parts.append("subrole=\(subrole)") }
        if let title, !title.isEmpty { parts.append("title=\"\(title)\"") }
        if let label, !label.isEmpty { parts.append("label=\"\(label)\"") }
        if let identifier, !identifier.isEmpty { parts.append("id=\"\(identifier)\"") }
        if let value, !value.isEmpty { parts.append("value=\"\(value.prefix(80))\"") }
        parts.append("enabled=\(isEnabled)")
        if isFocused { parts.append("focused=true") }
        if let frame { parts.append("frame[\(frame.summary)] center=(\(ComputerUseRect.format(frame.centerX)), \(ComputerUseRect.format(frame.centerY)))") }
        if !actions.isEmpty { parts.append("actions=[\(actions.joined(separator: ","))]") }
        parts.append("children=\(childCount)")
        return parts.joined(separator: " ")
    }

    public var jsonObject: [String: Any] {
        var dict: [String: Any] = [
            "pid": Int(pid),
            "role": role,
            "enabled": isEnabled,
            "focused": isFocused,
            "actions": actions,
            "childCount": childCount
        ]
        if let subrole { dict["subrole"] = subrole }
        if let title { dict["title"] = title }
        if let label { dict["label"] = label }
        if let identifier { dict["identifier"] = identifier }
        if let value { dict["value"] = value }
        if let frame {
            dict["frame"] = ["x": frame.x, "y": frame.y, "width": frame.width, "height": frame.height]
            dict["center"] = ["x": frame.centerX, "y": frame.centerY]
        }
        return dict
    }
}

#if os(macOS)
/// Accessibility inspection and actions via AXUIElement.
///
/// All traversal is bounded (depth + element count from
/// `ComputerUseSafety.Limits`) because real-world trees can be huge,
/// malformed or effectively unbounded; a truncated result says so.
public enum ComputerUseAccessibility {

    // MARK: - Element creation

    public static func applicationElement(pid: Int32) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    public static func systemWideElement() -> AXUIElement {
        AXUIElementCreateSystemWide()
    }

    // MARK: - Attribute reading

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let url = value as? URL { return url.absoluteString }
        return nil
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        (copyAttribute(element, attribute) as? NSNumber)?.boolValue ?? false
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetType(axValue) == .cgPoint,
              AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetType(axValue) == .cgSize,
              AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else {
            return []
        }
        return value
    }

    private static func actionNames(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let names else { return [] }
        return (names as [AnyObject]).compactMap { $0 as? String }
    }

    private static func pid(of element: AXUIElement) -> Int32 {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    // MARK: - Snapshots

    public static func snapshot(of element: AXUIElement) -> ComputerUseElementSnapshot {
        let position = pointAttribute(element, kAXPositionAttribute as String)
        let size = sizeAttribute(element, kAXSizeAttribute as String)
        var frame: ComputerUseRect?
        if let position, let size {
            frame = ComputerUseRect(
                x: Double(position.x), y: Double(position.y),
                width: Double(size.width), height: Double(size.height)
            )
        }
        return ComputerUseElementSnapshot(
            pid: pid(of: element),
            role: stringAttribute(element, kAXRoleAttribute as String) ?? "AXUnknown",
            subrole: stringAttribute(element, kAXSubroleAttribute as String),
            title: stringAttribute(element, kAXTitleAttribute as String),
            label: stringAttribute(element, kAXDescriptionAttribute as String),
            identifier: stringAttribute(element, kAXIdentifierAttribute as String),
            value: stringAttribute(element, kAXValueAttribute as String),
            isEnabled: boolAttribute(element, kAXEnabledAttribute as String),
            isFocused: boolAttribute(element, kAXFocusedAttribute as String),
            frame: frame,
            actions: actionNames(of: element),
            childCount: children(of: element).count
        )
    }

    // MARK: - Tree traversal

    /// A bounded depth-first dump of an app's accessibility tree.
    /// Returns the rendered tree, how many elements were visited, and
    /// whether the bounds cut the traversal short.
    public static func treeText(
        pid: Int32,
        maxDepth: Int,
        maxElements: Int
    ) -> (text: String, visited: Int, truncated: Bool) {
        let root = applicationElement(pid: pid)
        var lines: [String] = []
        var visited = 0
        var truncated = false

        func visit(_ element: AXUIElement, depth: Int) {
            if visited >= maxElements {
                truncated = true
                return
            }
            visited += 1
            let snap = snapshot(of: element)
            lines.append(String(repeating: "  ", count: depth) + snap.summary)
            guard depth < maxDepth else {
                if snap.childCount > 0 { truncated = true }
                return
            }
            for child in children(of: element) {
                if visited >= maxElements { truncated = true; return }
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return (lines.joined(separator: "\n"), visited, truncated)
    }

    // MARK: - Finding elements

    /// Criteria for `find`. Every non-nil field must match
    /// (case-insensitive; title/label/value match as substrings,
    /// role/identifier match exactly).
    public struct Query: Sendable {
        public var role: String?
        public var title: String?
        public var label: String?
        public var identifier: String?
        public var value: String?
        public init(role: String? = nil, title: String? = nil, label: String? = nil, identifier: String? = nil, value: String? = nil) {
            self.role = role
            self.title = title
            self.label = label
            self.identifier = identifier
            self.value = value
        }

        public var isEmpty: Bool {
            role == nil && title == nil && label == nil && identifier == nil && value == nil
        }

        func matches(_ snap: ComputerUseElementSnapshot) -> Bool {
            if let role, snap.role.caseInsensitiveCompare(role) != .orderedSame { return false }
            if let identifier, snap.identifier?.caseInsensitiveCompare(identifier) != .orderedSame { return false }
            if let title, snap.title?.localizedCaseInsensitiveContains(title) != true { return false }
            if let label, snap.label?.localizedCaseInsensitiveContains(label) != true { return false }
            if let value, snap.value?.localizedCaseInsensitiveContains(value) != true { return false }
            return true
        }
    }

    /// Finds live elements matching a query. Returns the elements with
    /// their snapshots so callers can act immediately (same call).
    public static func findElements(
        pid: Int32,
        query: Query,
        maxResults: Int = 20,
        maxDepth: Int = ComputerUseSafety.Limits.maxAccessibilityDepth,
        maxVisited: Int = ComputerUseSafety.Limits.maxAccessibilityElements * 4
    ) -> [(element: AXUIElement, snapshot: ComputerUseElementSnapshot)] {
        let root = applicationElement(pid: pid)
        var results: [(AXUIElement, ComputerUseElementSnapshot)] = []
        var visited = 0

        func visit(_ element: AXUIElement, depth: Int) {
            if visited >= maxVisited || results.count >= maxResults { return }
            visited += 1
            let snap = snapshot(of: element)
            if query.matches(snap) {
                results.append((element, snap))
            }
            guard depth < maxDepth else { return }
            for child in children(of: element) {
                if visited >= maxVisited || results.count >= maxResults { return }
                visit(child, depth: depth + 1)
            }
        }

        visit(root, depth: 0)
        return results
    }

    /// Resolves exactly one element for an action: a query must match
    /// precisely one element, otherwise the caller gets a structured
    /// notFound/ambiguous error instead of a guessed target.
    public static func resolveUniqueElement(pid: Int32, query: Query) throws -> (element: AXUIElement, snapshot: ComputerUseElementSnapshot) {
        guard !query.isEmpty else {
            throw ComputerUseError.invalidArgument("Provide at least one of role, title, label, identifier or value to identify the element, or x/y coordinates to target the element at a point.")
        }
        let matches = findElements(pid: pid, query: query)
        if matches.isEmpty {
            throw ComputerUseError.notFound("accessibility element matching the query in pid \(pid). Re-observe with computer_get_accessibility_tree; the app may not expose this UI to accessibility.")
        }
        if matches.count > 1 {
            throw ComputerUseError.ambiguous(
                "\(matches.count) elements match the query in pid \(pid)",
                candidates: matches.map { $0.snapshot.summary }
            )
        }
        return matches[0]
    }

    /// The element at a global point, via the system-wide element.
    public static func elementAt(pointX x: Double, pointY y: Double) throws -> (element: AXUIElement, snapshot: ComputerUseElementSnapshot) {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(systemWideElement(), Float(x), Float(y), &element)
        guard error == .success, let element else {
            throw ComputerUseError.executionFailed("AXUIElementCopyElementAtPosition failed (\(error.rawValue)) at (\(x), \(y)). The point may be over the desktop or an app that exposes no accessibility element there.")
        }
        return (element, snapshot(of: element))
    }

    /// The focused element of an application, when it exposes one.
    public static func focusedElement(pid: Int32) -> (element: AXUIElement, snapshot: ComputerUseElementSnapshot)? {
        let app = applicationElement(pid: pid)
        guard let value = copyAttribute(app, kAXFocusedUIElementAttribute as String),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        return (element, snapshot(of: element))
    }

    // MARK: - Actions

    /// Performs an accessibility action (default `AXPress`) on an
    /// element after checking the element actually advertises it.
    public static func performAction(_ action: String, on element: AXUIElement, snapshot: ComputerUseElementSnapshot) throws {
        let available = actionNames(of: element)
        guard available.contains(action) else {
            throw ComputerUseError.unsupported("Element [\(snapshot.summary)] does not advertise action \(action). Advertised actions: \(available.isEmpty ? "none" : available.joined(separator: ", ")).")
        }
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success else {
            throw ComputerUseError.executionFailed("AXUIElementPerformAction(\(action)) failed with AXError \(error.rawValue) on [\(snapshot.summary)].")
        }
    }

    /// Sets an element's value when the attribute is settable (text
    /// fields, sliders, checkboxes via value, …).
    public static func setValue(_ value: String, on element: AXUIElement, snapshot: ComputerUseElementSnapshot) throws {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else {
            throw ComputerUseError.unsupported("Element [\(snapshot.summary)] does not expose a settable value attribute. Use keyboard typing after focusing it, or an advertised action from: \(snapshot.actions.joined(separator: ", ")).")
        }
        let error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        guard error == .success else {
            throw ComputerUseError.executionFailed("Setting the element's value failed with AXError \(error.rawValue) on [\(snapshot.summary)].")
        }
    }
}
#endif
