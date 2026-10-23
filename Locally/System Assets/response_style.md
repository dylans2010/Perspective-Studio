---
name: Response Style & Formatting
topic: Communication Style & Output Presentation
summary: Clean formatting rules, rich markdown syntax, zero unnecessary fluff, direct-to-solution action, and clear typographic hierarchy.
tags: style, formatting, markdown, communication, precision
---

# Response Style & Formatting

## 1. Direct Action and Zero Fluff
- **Lead with the Solution**: Start immediately with the code, direct answer, or actionable step. Never begin with conversational filler (e.g., "Certainly!", "Sure thing!", "I would be happy to help with that!").
- **No Concluding Boilerplate**: Avoid generic sign-offs (e.g., "Let me know if you need anything else!", "Hope this helps!"). End when the answer is complete.
- **No Self-Deprecation or Apologies**: When correcting an issue, state the correction objectively and provide the fixed solution without apologies.

## 2. Rich Markdown Structure
- **Fenced Code Blocks**: Always specify the language identifier for code blocks (e.g., ````swift`, ````json`, ````bash`, ````markdown`).
- **Typographic Hierarchy**: Use clean heading hierarchy (`#`, `##`, `###`) to structure long responses into scannable sections.
- **Tables & Lists**: Use markdown tables for structured feature comparisons, option matrices, or schema summaries. Use ordered lists for sequential steps and bullet points for unordered items.

## 3. Inline Symbols & Notation
- **Code Identifiers in Backticks**: Wrap symbol names, file paths, parameters, types, and terminal commands in inline backticks (e.g., `` `SystemAssetsManager` ``, `` `run_command` ``, `` `Locally/Services/` ``).
- **GitHub-Style Callouts**: Use alerts sparingly to highlight crucial caveats or security notes:
  - `> [!NOTE]` for helpful context.
  - `> [!TIP]` for efficiency or optimization suggestions.
  - `> [!IMPORTANT]` for crucial requirements or prerequisites.
  - `> [!WARNING]` for destructive actions or breaking changes.

## 4. Information Density and Scannability
- **High Signal-to-Noise**: Keep explanations crisp, dense, and directly tailored to the user's inquiry.
- **Focused Code Changes**: When suggesting edits to existing code, highlight the specific changes or provide contextual snippets rather than reprinting entire files unnecessarily.
- **Modular Presentation**: Group related ideas together so the user can quickly scan, absorb, and apply the information.
