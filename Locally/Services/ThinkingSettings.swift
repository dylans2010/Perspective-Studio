import Foundation

/// The single source of truth for Thinking Mode settings.
///
/// The Settings UI and the chat toolbar bind these keys with
/// `@AppStorage`, whose declared default is `true` — but `@AppStorage`
/// never *writes* that default to `UserDefaults`. Every inference call
/// site used to read the key with `UserDefaults.standard.bool(forKey:)`,
/// which is `false` for a key that was never written, so on a fresh
/// install (or until the user happened to toggle the switch) the model
/// was never told to put its reasoning inside `<thinking>` tags at all.
/// Its chain-of-thought then arrived as ordinary prose and rendered as
/// the answer — "thinking showing as AI text" — even though the parser
/// and `ThinkingModelUI` were working exactly as written.
///
/// All inference paths (Chat, Agent, Quick Chat) read through here, so
/// the effective default matches the UI the user sees: thinking ON,
/// medium budget, until the user explicitly changes it.
public enum ThinkingSettings {

    public static let enabledKey = "enableThinkingMode"
    public static let budgetKey = "thinkingBudget"

    /// Effective Thinking Mode state: the stored value when the user has
    /// set one, otherwise the UI's declared default (`true`).
    public nonisolated static var isEnabled: Bool {
        if let stored = UserDefaults.standard.object(forKey: enabledKey) as? Bool {
            return stored
        }
        return true
    }

    public nonisolated static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    /// "low" / "medium" / "high" — stored value, or the UI default.
    public nonisolated static var budget: String {
        UserDefaults.standard.string(forKey: budgetKey) ?? "medium"
    }
}
