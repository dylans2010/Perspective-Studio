import Foundation

public enum ToolCallStatus: Equatable, Sendable {
    case pending
    case running
    case completed
    case failed(String)
    case cancelled
    case requiresConfirmation
}
