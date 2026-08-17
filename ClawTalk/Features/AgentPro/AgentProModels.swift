import Foundation

/// AgentPro 高级面板模型（gateway RPC 响应，字段全 optional 容错 + snake_case 兼容）。
/// 解码统一用 convertFromSnakeCase（camelCase 键原样保留）。

// MARK: - Usage

struct UsageCostResponse: Codable {
    var daily: [UsageDay]?
    var totals: UsageTotals?
    var cacheStatus: String?
}

struct UsageDay: Codable, Identifiable {
    var date: String?
    var totalTokens: Double?
    var totalCost: Double?
    var id: String { date ?? UUID().uuidString }
}

struct UsageTotals: Codable {
    var totalTokens: Double?
    var totalCost: Double?
}

// MARK: - Cron

struct CronListResponse: Codable {
    var jobs: [CronJob]?
    var snapshotRevision: Int?
    var total: Int?
}

struct CronJob: Codable, Identifiable {
    var id: String?
    var name: String?
    var expression: String?
    var enabled: Bool?
    var status: String?
    var configRevision: Int?
    var lastRunAt: String?
    var nextRunAt: String?
    var schedule: String?
    var timeout: Double?
}

struct CronStatusResponse: Codable {
    var running: Bool?
    var paused: Bool?
    var lastRunAt: String?
    var nextRunAt: String?
    var lastError: String?
}

// MARK: - Skills

struct SkillsStatusResponse: Codable {
    var skills: [SkillItem]?
    var agentId: String?
    var error: String?
}

struct SkillItem: Codable, Identifiable {
    var id: String?
    var name: String?
    var version: String?
    var enabled: Bool?
    var source: String?
    var description: String?
}

// MARK: - Doctor / Memory

struct DoctorMemoryStatus: Codable {
    var healthy: Bool?
    var layers: [MemoryLayerStatus]?
    var lastDream: String?
    var memoryCount: Int?
    var status: String?
}

struct MemoryLayerStatus: Codable, Identifiable {
    var id: String? { layer }
    var layer: String?
    var count: Int?
    var healthy: Bool?
    var lastAccess: String?
}

// MARK: - System

struct SystemInfo: Codable {
    var processInstanceId: String?
    var version: String?
    var platform: String?
    var os: String?
    var hostname: String?
    var uptimeMs: Double?
    var gatewayUrl: String?
    var connectedNodes: Int?
    var operatorCount: Int?
}


// MARK: - Dream Diary（doctor.memory.dreamDiary）

struct DreamDiaryResponse: Codable {
    var days: [DreamDiaryDay]?
    var entries: [DreamDiaryEntry]?
    var total: Int?
}

struct DreamDiaryDay: Codable, Identifiable {
    var id: String? { date }
    var date: String?
    var entries: Int?
    var summary: String?
}

struct DreamDiaryEntry: Codable, Identifiable {
    var id: String? { entryId }
    var entryId: String?
    var date: String?
    var summary: String?
    var content: String?
    var tags: [String]?
}

// MARK: - Skills 搜索/安装（skills.search / skills.detail / skills.install / skills.update）

struct SkillsSearchResponse: Codable {
    var results: [SkillItem]?
    var query: String?
    var total: Int?
}

struct SkillsInstallParams: Codable {
    var slug: String
    var agentId: String?
}

struct SkillsUpdateParams: Codable {
    var id: String?
    var slug: String?
    var agentId: String?
    var version: String?
}

/// Data → 可读 JSON 文本（AgentPro 通用展示兜底）。
func prettyJSONText(_ data: Data) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data, options: []),
       let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: pretty, encoding: .utf8) {
        return text
    }
    return String(data: data, encoding: .utf8) ?? "（无法解析响应）"
}