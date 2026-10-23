import Foundation

/// Registration point for the Computer Use tool suite.
///
/// Computer Use is built from scratch on macOS frameworks
/// (ScreenCaptureKit, Accessibility, Vision, CGEvent, NSWorkspace) —
/// it uses no external computer-use SDK. Tools plug into Locally's
/// existing registry exactly like every other tool: each is an
/// `AssistTool` value with a real schema, and `ToolsRegistry`
/// dispatches, validates required arguments and surfaces them to the
/// model.
///
/// Registration is idempotent by construction: `ToolsRegistry` keys
/// tools by lowercased id, and `registerAll(into:)` here is called
/// once from `registerBuiltInTools()`. Re-calling it replaces the same
/// keys — it can never create duplicates.
public enum ComputerUseToolRegistry {

    /// Every Computer Use tool id, in documentation order. The
    /// `computer_use` System Asset must name exactly these ids; a unit
    /// test enforces that the two never drift apart.
    public static let toolIDs: [String] = [
        "computer_get_permissions",
        "computer_screenshot",
        "computer_get_screen_info",
        "computer_read_screen_text",
        "computer_get_accessibility_tree",
        "computer_find_ui_element",
        "computer_perform_accessibility_action",
        "computer_mouse_click",
        "computer_mouse_move",
        "computer_mouse_scroll",
        "computer_mouse_drag",
        "computer_keyboard_type",
        "computer_keyboard_press",
        "computer_keyboard_shortcut",
        "computer_list_applications",
        "computer_open_application",
        "computer_focus_application",
        "computer_get_focused_application",
        "computer_close_application",
        "computer_list_windows",
        "computer_focus_window",
        "computer_move_window",
        "computer_resize_window",
        "computer_minimize_window",
        "computer_restore_window",
        "computer_wait",
        "computer_verify_state"
    ]

    /// Fresh instances of every Computer Use tool.
    public static var allTools: [any AssistTool] {
        [
            ComputerGetPermissionsTool(),
            ComputerScreenshotTool(),
            ComputerGetScreenInfoTool(),
            ComputerReadScreenTextTool(),
            ComputerGetAccessibilityTreeTool(),
            ComputerFindUIElementTool(),
            ComputerPerformAccessibilityActionTool(),
            ComputerMouseClickTool(),
            ComputerMouseMoveTool(),
            ComputerMouseScrollTool(),
            ComputerMouseDragTool(),
            ComputerKeyboardTypeTool(),
            ComputerKeyboardPressTool(),
            ComputerKeyboardShortcutTool(),
            ComputerListApplicationsTool(),
            ComputerOpenApplicationTool(),
            ComputerFocusApplicationTool(),
            ComputerGetFocusedApplicationTool(),
            ComputerCloseApplicationTool(),
            ComputerListWindowsTool(),
            ComputerFocusWindowTool(),
            ComputerMoveWindowTool(),
            ComputerResizeWindowTool(),
            ComputerMinimizeWindowTool(),
            ComputerRestoreWindowTool(),
            ComputerWaitTool(),
            ComputerVerifyStateTool()
        ]
    }

    /// Registers the whole suite into a registry.
    @MainActor
    public static func registerAll(into registry: ToolsRegistry) {
        for tool in allTools {
            registry.register(tool: tool)
        }
    }
}
