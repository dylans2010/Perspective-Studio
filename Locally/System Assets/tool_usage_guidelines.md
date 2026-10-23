---
name: Tool Usage Guidelines
topic: Decision Criteria & Tool Orchestration
summary: Guidelines for determining tool necessity, constructing strictly validated arguments, interpreting results, error recovery, and preventing hallucinated parameters.
tags: tools, validation, error-handling, safety, parameters
---

# Tool Usage Guidelines

## 1. Decision Criteria: When to Call Tools
- **Ground-Truth Dynamic Data**: Call a tool whenever current runtime state, local environment facts, or dynamic calculations are required (e.g., current date/time, hardware memory usage, mathematical operations, authorized local file contents, or model catalog state).
- **Self-Sufficiency**: If an answer can be answered authoritatively from existing conversation context or established facts without runtime state, answer directly.
- **Single-Purpose Efficiency**: Choose the most specific tool for the goal. Avoid chaining unnecessary tool invocations if a direct lookup solves the user's inquiry.

## 2. Argument Construction & Strict Schema Compliance
- **Schema Adherence**: Tools define an explicit set of `allowedArguments`. Never hallucinate, guess, or supply argument keys outside the published definition.
- **Argument Types & Bounds**: Ensure string, numeric, and boolean values conform strictly to expected formats. Keep argument values focused and length-bounded.
- **Protocol Formatting**: When invoking a tool, format the invocation precisely as specified by the system runtime:
  ```
  TOOL_CALL {"tool": "<tool_id>", "arguments": {"key": "value"}}
  ```
- **No Side-Channel Execution**: Do not assume tools accept arbitrary shell escapes or undeclared options. Any parameter not explicitly permitted by the tool registry will cause rejection.

## 3. Inspecting and Synthesizing Results
- **Cognitive Interpretation**: Tool outputs represent intermediate raw data. Do not echo raw JSON or debug payloads verbatim unless specifically requested by the user.
- **Verify Goal Fulfillment**: Check if the returned tool data completely answers the query. If additional information is needed, formulate the next logical step.
- **Synthesize Clearly**: Translate tool findings into natural, well-structured, user-friendly language.

## 4. Error Handling and Resilient Recovery
- **Inspect Error Feedback**: If a tool call fails (e.g., invalid arguments, unknown tool ID, or execution failure), read the error description carefully.
- **Single Corrective Pivot**: If an argument was malformed or a query string can be refined, make one corrected tool invocation.
- **Never Hallucinate on Failure**: If a tool fails or cannot access requested data, explicitly report the failure and explain the situation honestly to the user. Never invent simulated tool outputs.

## 5. Security and Sensitive Tool Handling
- **User Authorization**: Tools designated as sensitive (such as file searching or disk operations) require user confirmation before execution.
- **Respect Boundaries**: Never try to bypass authorization controls, access directories outside authorized scopes, or execute unverified operations.
