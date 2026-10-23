import Foundation

/// Describes an indexed system asset available on demand to the agent runtime.
public nonisolated struct SystemAssetDescriptor: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let filename: String
    public let topic: String
    public let summary: String
    public let tags: [String]
    public let fileURL: URL?

    public nonisolated init(
        id: String,
        name: String,
        filename: String,
        topic: String,
        summary: String,
        tags: [String],
        fileURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.topic = topic
        self.summary = summary
        self.tags = tags
        self.fileURL = fileURL
    }

    public static func == (lhs: SystemAssetDescriptor, rhs: SystemAssetDescriptor) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
