---
name: Coding Standards
topic: Modern Swift, Concurrency & macOS HIG
summary: Engineering standards for modern Swift, strict concurrency, SwiftUI @Observable state management, safe defensive coding, and Apple Human Interface Guidelines.
tags: swift, swiftui, macos, concurrency, hig, architecture
---

# Coding Standards & Architecture

## 1. Modern Swift & Strict Concurrency
- **Swift Version**: Target modern Swift (Swift 6.2+) with strict concurrency checks enabled.
- **Async/Await**: Always prefer structured concurrency (`async`/`await`, `TaskGroup`, `AsyncStream`) over closure-based asynchronous APIs and legacy Grand Central Dispatch (`DispatchQueue`).
- **Actor Isolation**: Isolate UI-facing data and state with `@MainActor`. Ensure background computations run detached or in background actors where appropriate.
- **Sendability**: Types crossing concurrency boundaries must conform to `Sendable`. Prefer immutable `struct` types for data transfer.

## 2. State Management with SwiftUI
- **`@Observable` Macro**: Use `@Observable` for shared state and view models. Mark observable classes `@MainActor`.
- **Avoid Legacy Observation**: Do not use `ObservableObject`, `@Published`, `@StateObject`, or `@ObservedObject` in new code.
- **State Property Wrappers**:
  - `@State` for state ownership within the view lifecycle.
  - `@Bindable` when deriving bindings from an `@Observable` model.
  - `@Environment` for dependency injection and environment propagation.
- **View Hierarchy**: Decompose complex views into smaller dedicated `View` structs rather than sprawling computed properties. Avoid `AnyView`.

## 3. Defensive and Safe Coding Patterns
- **No Force Unwrapping**: Avoid force unwrapping (`!`) and force `try!`. Always use optional binding (`if let`, `guard let`), default coalescing (`??`), or typed error handling (`do-catch`).
- **Modern Foundation APIs**:
  - Use `URL.documentsDirectory` and `url.appending(path: ...)` instead of legacy file path manipulation.
  - Use modern Swift string methods like `string.replacing("target", with: "replacement")`.
  - Use modern `FormatStyle` for formatting dates, numbers, and currencies (e.g., `date.formatted(date: .abbreviated, time: .shortened)`).
  - Use `localizedStandardContains(_:)` for user-facing search and filtering.

## 4. macOS Human Interface Guidelines (HIG)
- **Native Look and Feel**: Embrace native macOS controls, vibrant materials, standard sidebar/detail navigation (`NavigationSplitView`, `NavigationStack`), and toolbar layouts.
- **SF Symbols**: Use standard Apple SF Symbols with hierarchical or monochrome styling for intuitive visual cues.
- **Modifiers**: Use `foregroundStyle()` over `foregroundColor()`, and `clipShape(.rect(cornerRadius:))` over legacy corner radii.
- **Accessibility & Dynamic Type**: Maintain accessible contrast, keyboard navigation shortcuts, VoiceOver labels, and support for Dynamic Type sizing.
