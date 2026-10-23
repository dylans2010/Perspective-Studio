import Foundation

struct ToolRunStep: Identifiable, Sendable {
    var id: UUID = UUID()
    let title: String
    let detail: String
}

enum ToolRunOutcome: Sendable {
    /// Final answer after any tool round-trip.
    case finished(answer: String, steps: [ToolRunStep])
    /// A tool needs the user's explicit confirmation before it may run.
    case needsConfirmation(toolID: String, arguments: [String: String], steps: [ToolRunStep])
    case failed(String, steps: [ToolRunStep])
}

/// Orchestrates one tool-enabled exchange (feature K):
/// 1. Ask the loaded model, with the bounded tool list, to either answer or
///    emit exactly one `TOOL_CALL {"tool": "...", "arguments": {...}}`.
/// 2. Parse + validate that call against the registry (unknown tools and
///    unexpected argument keys are rejected — the model's output is
///    untrusted input).
/// 3. Sensitive tools stop for user confirmation; the UI re-runs with
///    `confirmedToolIDs` containing the approved tool.
/// 4. The real tool result is fed back to the model for the final answer.
@MainActor
enum ToolCallingService {
    static func run(
        prompt: String,
        model: InstalledModel,
        confirmedToolIDs: Set<String> = [],
        backend: any InferenceBackend = InferenceBackends.default
    ) async -> ToolRunOutcome {
        var steps: [ToolRunStep] = []
        do {
            _ = try await backend.load(model: model)
            let toolList = ToolRegistry.shared.tools
                .map { "- \($0.id): \($0.toolDescription)" }
                .joined(separator: "\n")
            let instruction = """
            You can use tools. If a tool would help, reply with exactly one line:
            TOOL_CALL {"tool": "<tool id>", "arguments": {"key": "value"}}
            Otherwise answer directly. Available tools:
            \(toolList)
            """
            let first = try await backend.generate(prompt: prompt, systemPrompt: instruction)
            guard let call = parseToolCall(in: first.text) else {
                steps.append(ToolRunStep(title: "Model answered directly", detail: "No tool was requested."))
                return .finished(answer: first.text, steps: steps)
            }
            steps.append(ToolRunStep(title: "Model requested \(ToolNameFormatter.format(call.toolID))", detail: "\(call.arguments)"))

            guard let definition = ToolRegistry.shared.definition(for: call.toolID) else {
                return .failed("The model requested an action the agent does not have, so nothing was executed.", steps: steps)
            }
            if definition.requiresConfirmation && !confirmedToolIDs.contains(call.toolID) {
                return .needsConfirmation(toolID: call.toolID, arguments: call.arguments, steps: steps)
            }

            let result = try await ToolRegistry.shared.execute(
                toolID: call.toolID,
                arguments: call.arguments,
                confirmed: true
            )
            steps.append(ToolRunStep(title: "Executed \(definition.name)", detail: result))

            let followUp = try await backend.generate(
                prompt: "The user asked: \(prompt)\n\nThe \(definition.name) tool returned:\n\(result)\n\nGive the final answer using that result.",
                systemPrompt: nil
            )
            return .finished(answer: followUp.text, steps: steps)
        } catch {
            return .failed(error.localizedDescription, steps: steps)
        }
    }

    /// Extracts and validates the JSON payload of a `TOOL_CALL` line.
    /// Returns nil when the model did not request a tool.
    nonisolated static func parseToolCall(in text: String) -> (toolID: String, arguments: [String: String])? {
        guard let marker = text.range(of: "TOOL_CALL") else { return nil }
        let remainder = text[marker.upperBound...]
        guard let start = remainder.firstIndex(of: "{"),
              let data = balancedJSON(in: remainder[start...]),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolID = object["tool"] as? String else { return nil }
        var arguments: [String: String] = [:]
        if let rawArgs = object["arguments"] as? [String: Any] {
            for (key, value) in rawArgs {
                if let string = value as? String {
                    arguments[key] = string
                } else if let number = value as? NSNumber {
                    arguments[key] = number.stringValue
                } else {
                    return nil // Non-scalar arguments are rejected outright.
                }
            }
        }
        return (toolID, arguments)
    }

    /// Finds the balanced `{...}` JSON object at the start of `text`.
    private nonisolated static func balancedJSON(in text: Substring) -> Data? {
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, char) in text.enumerated() {
            if escaped { escaped = false; continue }
            if char == "\\" && inString { escaped = true; continue }
            if char == "\"" { inString.toggle(); continue }
            if inString { continue }
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    let end = text.index(text.startIndex, offsetBy: offset + 1)
                    return Data(text[text.startIndex..<end].utf8)
                }
            }
        }
        return nil
    }
}
