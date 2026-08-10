import Foundation

// MARK: - API服务
class APIService {

    static let shared = APIService()

    // API基础URL - 需要替换为实际的API地址
    private let baseURL = "https://api.example.com"

    private init() {}

    // MARK: - 帮你回 - 生成回复
    func generateHelpReply(
        content: String,
        roleId: String,
        count: Int = 5
    ) async throws -> [String] {
        let endpoint = "\(baseURL)/api/help-reply"
        let body: [String: Any] = [
            "content": content,
            "role_id": roleId,
            "count": count
        ]

        // 实际项目中需要调用真实API
        // 这里返回模拟数据
        return try await mockHelpReplyResponse(content: content, roleId: roleId, count: count)
    }

    // MARK: - 帮你回 - 使用人设生成回复
    func generateHelpReply(
        content: String,
        role: ChatRole,
        count: Int = 5
    ) async throws -> [String] {
        return try await generateHelpReply(content: content, roleId: role.id, count: count)
    }

    // MARK: - 超会说 - 生成润色回复
    func generateSuperTalk(
        content: String,
        identity: IdentityType,
        count: Int = 4
    ) async throws -> [PolishResult] {
        let endpoint = "\(baseURL)/api/super-talk"
        let body: [String: Any] = [
            "content": content,
            "identity": identity.rawValue,
            "count": count
        ]

        // 实际项目中需要调用真实API
        // 这里返回模拟数据
        return try await mockSuperTalkResponse(content: content, identity: identity, count: count)
    }

    // MARK: - 通用POST请求
    private func post<T: Decodable>(
        _ urlString: String,
        body: [String: Any]
    ) async throws -> T {
        do {
            guard let url = URL(string: urlString) else {
                throw APIError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.networkError
            }

            guard 200...299 ~= httpResponse.statusCode else {
                throw APIError.serverError(statusCode: httpResponse.statusCode)
            }

            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw APIError.decodingError
            }
        } catch {
            KeyboardLogCollector.record(module: "键盘网络", error.localizedDescription)
            throw error
        }
    }

    // MARK: - Mock数据（开发测试用）

    private func mockHelpReplyResponse(content: String, roleId: String, count: Int) async throws -> [String] {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 1_000_000_000)

        // 根据不同人设返回不同风格的回复
        let replies: [String]

        switch roleId {
        case "gentle_boyfriend":
            replies = [
                "亲爱的，我一直都在想你呢～",
                "宝贝，有什么事情可以跟我说，我会一直陪着你的",
                "你说的每一句话我都会认真听的，因为是你说的",
                "不管发生什么，我都会站在你这边的",
                "你开心就好，你的笑容是我最大的幸福"
            ]
        case "domineering_ceo":
            replies = [
                "你是我的，谁都不能欺负你",
                "有我在，你什么都不用担心",
                "听我的，这件事我来处理",
                "你只需要负责开心就好，其他的交给我",
                "我说过会保护你，就一定会做到"
            ]
        case "humor_boy":
            replies = [
                "哈哈，你这是在考验我的幽默细胞吗？",
                "别担心，有我这个开心果在，保证让你笑到肚子疼",
                "人生嘛，开心最重要，不开心的事就让它随风去吧～",
                "你知道吗？你笑起来的样子，比阳光还灿烂",
                "来来来，让我给你讲个笑话，保证你听完心情大好"
            ]
        default:
            replies = [
                "我理解你的感受，有什么我能帮到你的吗？",
                "谢谢你愿意和我分享，我会一直支持你的",
                "不管怎样，我都会陪在你身边",
                "你的想法很重要，我很认真地在听",
                "有你真好，让我们一起面对吧"
            ]
        }

        return Array(replies.prefix(count))
    }

    private func mockSuperTalkResponse(content: String, identity: IdentityType, count: Int) async throws -> [PolishResult] {
        // 模拟网络延迟
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let baseContent = content.isEmpty ? "我想你了" : content

        let results = [
            PolishResult(styleName: "撒娇", text: "人家好想你呀～你有没有想人家呢？💕"),
            PolishResult(styleName: "温柔", text: "亲爱的，我一直在想你，你现在在做什么呢？"),
            PolishResult(styleName: "幽默", text: "报告！有人正在疯狂想念你，请立即回复，否则后果自负！😄"),
            PolishResult(styleName: "浪漫", text: "每一秒的思念都像星星一样闪烁，而你就是我夜空中最亮的那颗✨")
        ]

        return Array(results.prefix(count))
    }
}

// MARK: - API错误类型
enum APIError: Error, LocalizedError {
    case invalidURL
    case networkError
    case serverError(statusCode: Int)
    case decodingError
    case noData

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的URL"
        case .networkError:
            return "网络连接失败，请检查网络设置"
        case .serverError(let statusCode):
            return "服务器错误 (\(statusCode))"
        case .decodingError:
            return "数据解析失败"
        case .noData:
            return "没有返回数据"
        }
    }
}
