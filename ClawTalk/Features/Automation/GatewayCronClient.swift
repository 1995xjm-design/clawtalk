import Foundation

/// 网关侧 cron 定时任务的 HTTP 客户端。
///
/// ⚠️ 端点约定（实现时假设，待网关侧确认）：
/// - GET    {gatewayURL}/cron/tasks          -> 任务列表
/// - POST   {gatewayURL}/cron/tasks          -> 创建（body = CronTaskPayload）
/// - PATCH  {gatewayURL}/cron/tasks/{id}     -> 更新 / 启停（body = CronTaskPayload 或 {"enabled": Bool}）
/// - DELETE {gatewayURL}/cron/tasks/{id}     -> 删除
///
/// 官方 OpenClaw（openclaw-official-main）macOS 端实际通过 WebSocket RPC 操作 cron：
///   cron.list / cron.add / cron.update / cron.remove / cron.status / cron.runs / cron.run
/// （apps/macos/Sources/OpenClaw/GatewayConnection.swift 的 RPC 枚举已确认）。
/// 若网关侧不提供上述 REST 端点，可改用 /tools/invoke（tool: "cron_list" / "cron_create" /
/// "cron_delete" / "cron_set_enabled"），方法体结构不变，只需替换 URL 与解析方式。
/// 本文件的 HTTP 逻辑已完整可跑：URLRequest + Bearer token + JSON 编解码，失败抛错。
final class GatewayCronClient {

    /// 网关 baseURL（如 http://124.156.180.143:18789）
    let gatewayURL: String
    /// 网关鉴权 token（Bearer）
    let token: String

    /// 探测到的端点（nil = 尚未探测 / 探测失败）
    private(set) var resolvedEndpoint: GatewayCronEndpoint?

    /// 端点是否已探测成功（视图层据此显示「仅本机」提示或可同步状态）。
    var isEndpointReady: Bool { resolvedEndpoint != nil }

    /// 候选端点自动探测：/cron/tasks → /cron/list → WS cron.list（仅提示）。
    /// 返回诚实状态文本（视图层直接展示）。
    func probeEndpoints() async -> String {
        if await probe(path: "/tasks") {
            resolvedEndpoint = .restTasks
            return "已探测到网关 cron 接口（/cron/tasks），任务可同步"
        }
        if await probe(path: "/list") {
            resolvedEndpoint = .restList
            return "已探测到网关 cron 接口（/cron/list），任务可同步"
        }
        resolvedEndpoint = nil
        return "未探测到网关 cron 接口（已尝试 /cron/tasks、/cron/list）；如网关为 OpenClaw 官方版，cron 走 WebSocket cron.list RPC，本端暂不自动同步，仅显示本机任务"
    }

    /// 探测单个候选端点：HTTP 2xx 且响应能解析为任务列表 JSON 才算接通
    /// （避免网关 404 页返回 HTML 被误判为接口存在）。
    private func probe(path: String) async -> Bool {
        do {
            var request = try makeRequest(path: path, method: "GET")
            request.timeoutInterval = 6
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
            _ = try Self.decoder.decode(CronTaskListResponse.self, from: data)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 列表

    /// 拉取网关侧全部 cron 任务（按探测到的端点拼路径）。
    func listCronTasks() async throws -> [AutomationTask] {
        let path = resolvedEndpoint == .restList ? "/list" : "/tasks"
        let request = try makeRequest(path: path, method: "GET")
        let data = try await perform(request)
        let wrapper = try Self.decoder.decode(CronTaskListResponse.self, from: data)
        return wrapper.tasks ?? []
    }

    // MARK: - 创建

    /// 创建 cron 任务；返回网关保存后的任务（含网关生成的 id / nextRunAt）。
    /// 待确认端点：POST {gatewayURL}/cron/tasks，body = CronTaskPayload
    func createCronTask(_ task: AutomationTask) async throws -> AutomationTask {
        var request = try makeRequest(path: "/tasks", method: "POST")
        request.httpBody = try JSONEncoder().encode(CronTaskPayload(task: task))
        let data = try await perform(request)
        return try Self.decodeTask(from: data)
    }

    // MARK: - 更新

    /// 更新 cron 任务整体（含启停字段）。
    /// 待确认端点：PATCH {gatewayURL}/cron/tasks/{id}，body = CronTaskPayload
    func updateCronTask(_ task: AutomationTask) async throws -> AutomationTask {
        var request = try makeRequest(path: taskPath(task.id), method: "PATCH")
        request.httpBody = try JSONEncoder().encode(CronTaskPayload(task: task))
        let data = try await perform(request)
        return try Self.decodeTask(from: data)
    }

    // MARK: - 删除

    /// 删除 cron 任务。
    /// 待确认端点：DELETE {gatewayURL}/cron/tasks/{id}
    func deleteCronTask(id: String) async throws {
        let request = try makeRequest(path: taskPath(id), method: "DELETE")
        _ = try await perform(request)
    }

    // MARK: - 启停

    /// 启用/停用 cron 任务。
    /// 待确认端点：PATCH {gatewayURL}/cron/tasks/{id}，body = {"enabled": true|false}
    func setCronTaskEnabled(id: String, enabled: Bool) async throws {
        var request = try makeRequest(path: taskPath(id), method: "PATCH")
        request.httpBody = try JSONEncoder().encode(CronEnabledPayload(enabled: enabled))
        _ = try await perform(request)
    }

    // MARK: - HTTP 基础（URLRequest + Bearer token + JSON 编解码）

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        let trimmed = gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/cron\(path)") else {
            throw GatewayCronError.invalidURL
        }
        // 与 OpenClawClient 一致的安全校验（http/https 放行，非法 scheme 抛错）
        try OpenClawClient.validateConnectionSecurity(url)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayCronError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw GatewayCronError.httpError(http.statusCode)
        }
        return data
    }

    /// 任务 id 拼进路径前做百分号编码，避免特殊字符破坏路径。
    private func taskPath(_ id: String) -> String {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return "/tasks/\(id)"
        }
        return "/tasks/\(encoded)"
    }

    /// 解析任务响应：优先直接解 AutomationTask，兼容 {task: {...}} 包装。
    private static func decodeTask(from data: Data) throws -> AutomationTask {
        if let direct = try? Self.decoder.decode(AutomationTask.self, from: data) {
            return direct
        }
        if let wrapped = try? Self.decoder.decode(CronTaskResponse.self, from: data),
           let task = wrapped.task {
            return task
        }
        throw GatewayCronError.decodingFailed
    }

    /// 网关响应中的日期格式未知：兼容 ISO8601（含/不含小数秒）、毫秒时间戳、秒时间戳。
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                let formatters = [
                    ISO8601DateFormatter(),
                    Self.fractionalISOFormatter
                ]
                for formatter in formatters {
                    if let date = formatter.date(from: text) {
                        return date
                    }
                }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "无法解析网关时间：\(text)"
                )
            }
            if let milliseconds = try? container.decode(Int.self) {
                return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
            }
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "未知的网关时间格式"
            )
        }
        return decoder
    }()

    private static let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// 创建/更新 cron 任务的请求体（端点确认后按实际 JSON 调整）
struct CronTaskPayload: Encodable {
    let name: String
    let cronExpression: String
    let description: String
    let enabled: Bool

    init(task: AutomationTask) {
        self.name = task.name
        self.cronExpression = task.cronExpression
        self.description = task.description
        self.enabled = task.enabled
    }
}

/// 仅启停字段的请求体
struct CronEnabledPayload: Encodable {
    let enabled: Bool
}

/// cron 任务列表响应体（兼容 tasks 缺失/为 null）
struct CronTaskListResponse: Decodable {
    let tasks: [AutomationTask]?

    enum CodingKeys: String, CodingKey {
        case tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tasks = try container.decodeIfPresent([AutomationTask].self, forKey: .tasks) ?? []
    }
}

/// 创建/更新后的单任务响应体（兼容 {task: {...}} 包装）
struct CronTaskResponse: Decodable {
    let task: AutomationTask?
}

/// 网关 cron 接口错误
enum GatewayCronError: LocalizedError {
    case endpointNotImplemented(String)
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .endpointNotImplemented(let detail):
            return detail
        case .invalidURL:
            return "网关 cron 地址无效。"
        case .invalidResponse:
            return "网关 cron 返回了无效响应。"
        case .httpError(let code):
            return "网关 cron 返回 HTTP \(code)。"
        case .decodingFailed:
            return "网关 cron 响应解析失败。"
        }
    }
}

/// 网关 cron 候选端点（探测结果）。
enum GatewayCronEndpoint: Equatable {
    /// REST：GET {base}/cron/tasks
    case restTasks
    /// REST：GET {base}/cron/list
    case restList
    /// OpenClaw 官方 WebSocket RPC cron.list（本端仅标记，不实现 RPC）
    case webSocketRPC
}
