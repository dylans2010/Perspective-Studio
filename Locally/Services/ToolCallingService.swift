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

            // The same validation gate the agent loop uses: identity is
            // resolved against the registered catalog and arguments are
            // checked against the tool's schema BEFORE anything is
            // confirmed or dispatched. This path used to look the id up
            // directly and execute string arguments unvalidated — a
            // second, weaker pipeline next to the authoritative one.
            let catalog = ToolCatalog(tools: ToolsRegistry.shared.allTools)
            let codableArgs = call.arguments.mapValues { AnyCodableValue(any: $0) }
            let validated: ValidatedToolCall
            switch ToolCallValidator.validate(toolID: call.toolID, arguments: codableArgs, catalog: catalog) {
            case .accepted(let call):
                validated = call
            case .rejected(let rejection):
                steps.append(ToolRunStep(title: "Action Not Executed", detail: rejection.userFacingSummary))
                return .failed(rejection.userFacingSummary, steps: steps)
            }

            guard let definition = ToolRegistry.shared.definition(for: validated.toolID) else {
                return .failed("The model requested an action the agent does not have, so nothing was executed.", steps: steps)
            }
            if definition.requiresConfirmation && !confirmedToolIDs.contains(validated.toolID) {
                return .needsConfirmation(toolID: validated.toolID, arguments: call.arguments, steps: steps)
            }

            let result = try await ToolRegistry.shared.execute(
                toolID: validated.toolID,
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

    /// Extracts the JSON payload of a `TOOL_CALL` line, using the ONE
    /// authoritative decoder (`AntigravityAgentHarness.parseToolCall` —
    /// the same parser the agent loop's `AntigravityLoopEngine.decide`
    /// consumes). This service used to carry its own copy of the marker
    /// scan and balanced-brace walk; two decoders meant two definitions
    /// of what a call is, and fixes landed in one and not the other.
    ///
    /// Returns nil when the model did not request a tool. Argument values
    /// are flattened to strings for this service's legacy execute path;
    /// a non-scalar argument value rejects the parse outright (the
    /// caller reports that nothing was executed) — full structured
    /// arguments are the agent loop's channel, validated by
    /// `ToolCallValidator` in `run` above before dispatch either way.
    nonisolated static func parseToolCall(in text: String) -> (toolID: String, arguments: [String: String])? {
        guard let parsed = AntigravityAgentHarness.parseToolCall(in: text) else { return nil }
        var arguments: [String: String] = [:]
        for (key, value) in parsed.arguments {
            if let string = value as? String {
                arguments[key] = string
            } else if let number = value as? NSNumber {
                arguments[key] = number.stringValue
            } else {
                return nil // Non-scalar arguments are rejected outright.
            }
        }
        return (parsed.toolId, arguments)
    }
}
