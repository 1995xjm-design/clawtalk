import Foundation

/// 网关侧 cron 定时任务的 HTTP 接口骨架。
///
/// ⚠️ 端点待网关侧确认：OpenClaw 网关当前已知的 cron 能力是「cron: 前缀会话」
/// （SessionsView 已能识别），cron 任务的 REST 端点尚未确认。
/// 因此本文件保留完整方法签名 + 请求/响应体约定，方法体先返回空数组 /
/// 抛出「端点未接线」错误，方便后续按确认结果填充。
///
/// 接线候选（二选一，待确认）：
/// 1. 网关新增 REST 端点（如 GET/POST /cron/tasks、DELETE/PATCH /cron/tasks/{id}）
/// 2. 复用 /tools/invoke 工具（tool: "cron_list" / "cron_create" / "cron_delete" / "cron_set_enabled"）
struct GatewayCronClient {

    /// 网关 baseURL（如 http://124.156.180.143:18789）
    let gatewayURL: String
    /// 网关鉴权 token（Bearer）
    let token: String

    /// 端点是否已接线（网关侧确认前恒为 false；视图层据此显示「仅本机」提示）
    var isEndpointReady: Bool { false }

    // MARK: - 列表

    /// 拉取网关侧全部 cron 任务。
    /// 待网关侧确认端点：GET {gatewayURL}/cron/tasks
    func listCronTasks() async throws -> [AutomationTask] {
        // 接线时按此结构实现（参考 OpenClawClient.fetchModels 的 URLRequest 写法）：
        // var request = URLRequest(url: url)
        // request.httpMethod = "GET"
        // request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // 解析 CronTaskListResponse 后返回 tasks ?? []
        throw GatewayCronError.endpointNotImplemented("cron 任务列表接口待网关侧确认（GET /cron/tasks）")
    }

    // MARK: - 创建

    /// 创建 cron 任务；返回网关保存后的任务（含网关生成的 id / nextRunAt）。
    /// 待网关侧确认端点：POST {gatewayURL}/cron/tasks，body = CronTaskPayload
    func createCronTask(_ task: AutomationTask) async throws -> AutomationTask {
        throw GatewayCronError.endpointNotImplemented("cron 任务创建接口待网关侧确认（POST /cron/tasks）")
    }

    // MARK: - 删除

    /// 删除 cron 任务。
    /// 待网关侧确认端点：DELETE {gatewayURL}/cron/tasks/{id}
    func deleteCronTask(id: String) async throws {
        throw GatewayCronError.endpointNotImplemented("cron 任务删除接口待网关侧确认（DELETE /cron/tasks/{id}）")
    }

    // MARK: - 启停

    /// 启用/停用 cron 任务。
    /// 待网关侧确认端点：PATCH {gatewayURL}/cron/tasks/{id}，body = {"enabled": true|false}
    func setCronTaskEnabled(id: String, enabled: Bool) async throws {
        throw GatewayCronError.endpointNotImplemented("cron 任务启停接口待网关侧确认（PATCH /cron/tasks/{id}）")
    }
}

/// 创建/更新 cron 任务的请求体（端点确认后按实际 JSON 调整）
struct CronTaskPayload: Encodable {
    let name: String
    let cronExpression: String
    let description: String
    let enabled: Bool
}

/// cron 任务列表响应体（端点确认后按实际 JSON 调整）
struct CronTaskListResponse: Decodable {
    let tasks: [AutomationTask]?
}

/// 网关 cron 接口错误
enum GatewayCronError: LocalizedError {
    case endpointNotImplemented(String)

    var errorDescription: String? {
        switch self {
        case .endpointNotImplemented(let detail):
            return detail
        }
    }
}
