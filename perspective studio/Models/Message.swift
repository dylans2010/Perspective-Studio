import Foundation
import SwiftData

enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

@Model
final class Message {
    var id: UUID = UUID()
    var role: MessageRole = MessageRole.user
    var content: String = ""
    /// File names (inside Application Support/PerspectiveStudio/Attachments)
    /// of images attached to this message, so vision turns survive relaunch.
    var imageFileNames: [String] = []
    var timestamp: Date = Date.now
    var conversation: Conversation?

    init(role: MessageRole, content: String, conversation: Conversation? = nil) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = .now
        self.conversation = conversation
    }
}
