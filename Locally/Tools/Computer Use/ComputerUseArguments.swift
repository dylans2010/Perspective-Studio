import Foundation

/// Tolerant argument extraction for Computer Use tools.
///
/// Tool input arrives as `[String: Any]` from the agent harness (real
/// JSON values: numbers arrive as NSNumber/Int/Double, booleans as
/// Bool) or as `[String: String]` from the legacy string path in
/// `ToolsRegistry` / `ToolCallingService` (everything is a string).
/// These helpers accept both, plus JSON-stringified nested objects,
/// and return nil instead of trapping on a mistyped value so tools can
/// answer with a structured `invalidArgument` error.
public enum ComputerUseArguments {

    public static func string(_ input: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty { return value }
            if let number = input[key] as? NSNumber { return number.stringValue }
        }
        return nil
    }

    public static func bool(_ input: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            if let value = input[key] as? Bool { return value }
            if let value = input[key] as? String {
                switch value.lowercased() {
                case "true", "yes", "1": return true
                case "false", "no", "0": return false
                default: continue
                }
            }
            if let number = input[key] as? NSNumber { return number.boolValue }
        }
        return nil
    }

    public static func double(_ input: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = input[key] as? Double { return value }
            if let value = input[key] as? Int { return Double(value) }
            if let number = input[key] as? NSNumber { return number.doubleValue }
            if let value = input[key] as? String, let parsed = Double(value.trimmingCharacters(in: .whitespaces)) {
                return parsed
            }
        }
        return nil
    }

    public static func int(_ input: [String: Any], _ keys: String...) -> Int? {
        for key in keys {
            if let value = double(input, key) { return Int(value) }
        }
        return nil
    }

    /// A nested object argument (e.g. `region: {x, y, width, height}`),
    /// accepting a real dictionary or a JSON string encoding one.
    public static func object(_ input: [String: Any], _ key: String) -> [String: Any]? {
        if let dict = input[key] as? [String: Any] { return dict }
        if let string = input[key] as? String,
           let data = string.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parsed
        }
        return nil
    }

    /// Reads a point from flat `x`/`y` arguments or a nested `point`
    /// object with `x`/`y` keys.
    public static func point(_ input: [String: Any], xKeys: [String] = ["x"], yKeys: [String] = ["y"]) -> (x: Double, y: Double)? {
        if let nested = object(input, "point") ?? object(input, "position") ?? object(input, "coordinates"),
           let x = double(nested, "x"), let y = double(nested, "y") {
            return (x, y)
        }
        var foundX: Double?
        for key in xKeys { if let v = double(input, key) { foundX = v; break } }
        var foundY: Double?
        for key in yKeys { if let v = double(input, key) { foundY = v; break } }
        guard let x = foundX, let y = foundY else { return nil }
        return (x, y)
    }

    /// JSON-encodes a value for a tool result's `data` payload or output
    /// text. Returns a stable, sorted-keys string.
    public static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
