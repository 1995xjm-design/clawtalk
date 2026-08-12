import Foundation

enum MessageRole: String, Codable {
    case user
    case assistant
}

/// 聊天文件附件（方案 B：走网关 /v1/responses input_file，文本类/PDF ≤5MB）。
struct ChatFileAttachment: Codable, Equatable {
    let filename: String
    let mimeType: String
    let data: Data
}

struct Message: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var imageData: [Data]?
    var fileAttachment: ChatFileAttachment?
    var tokenUsage: TokenUsage?
    var responseId: String?
    var modelName: String?
    var sendError: String?

    init(role: MessageRole, content: String, isStreaming: Bool = false, imageData: [Data]? = nil, fileAttachment: ChatFileAttachment? = nil) {
        self.init(id: UUID(), role: role, content: content, isStreaming: isStreaming, imageData: imageData, fileAttachment: fileAttachment)
    }

    /// Specified-ID init: retries reuse the original id so cancellation cleanup can locate the message.
    init(id: UUID, role: MessageRole, content: String, isStreaming: Bool = false, imageData: [Data]? = nil, fileAttachment: ChatFileAttachment? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.isStreaming = isStreaming
        self.imageData = imageData
        self.fileAttachment = fileAttachment
    }

    var hasFile: Bool {
        fileAttachment != nil
    }

    var hasImages: Bool {
        guard let images = imageData else { return false }
        return !images.isEmpty
    }

    var hasFailed: Bool {
        sendError != nil
    }
}
