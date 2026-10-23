import Foundation

public enum ToolCallStatus: Equatable, Sendable {
    case running
    case completed
    case failed(String)
    case requiresConfirmation
}
