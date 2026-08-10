import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

struct Message: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var imageData: [Data]?
    var tokenUsage: TokenUsage?
    var responseId: String?
    var modelName: String?
    var sendError: String?

    init(role: MessageRole, content: String, isStreaming: Bool = false, imageData: [Data]? = nil) {
        self.init(id: UUID(), role: role, content: content, isStreaming: isStreaming, imageData: imageData)
    }

    /// Specified-ID init: retries reuse the original id so cancellation cleanup can locate the message.
    init(id: UUID, role: MessageRole, content: String, isStreaming: Bool = false, imageData: [Data]? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.imageData = imageData
    }

    var hasImages: Bool {
        guard let images = imageData else { return false }
        return !images.isEmpty
    }

    var hasFailed: Bool {
        sendError != nil
    }
}
