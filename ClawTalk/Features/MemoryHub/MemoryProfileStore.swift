import Foundation

/// 本地档案存储：UserDefaults JSON 持久化 + 从本地对话按简单规则聚合。
///
/// 第 4 层：新增网关记忆沉淀 —— 新识别的偏好/项目/灵感通过网关 memory_add
/// 写入智能体记忆（与 MemorySearchTabView 的 memory_search 同款调用方式）。
/// 诚实原则：网关调用失败静默不报错，本地档案始终保留；已成功推送的条目记录 id，
/// 不会重复上报；没有本地数据时 profiles 为空数组，由界面展示空状态，不造假。
@MainActor
@Observable
final class MemoryProfileStore {
    /// 当前档案条目（按分类顺序 + 最近更新时间排序），供界面直接展示。
    private(set) var profiles: [MemoryProfile] = []

    private let defaults = UserDefaults.standard
    private let snapshotKey = "memory_hub_profiles_v1"

    /// 网关配置（用于 memory_add 沉淀；nil = 未配置网关，只做本地聚合）
    private let settings: SettingsStore?
    private let client = OpenClawClient()

    private var entries: [MemoryProfile] = []
    /// 聚合键（分类|关键词）-> 条目 id：多次聚合时同一来源条目 id 保持稳定，避免列表抖动。
    private var keys: [String: UUID] = [:]
    /// 已成功写入网关记忆的条目 id（持久化，避免重复上报）
    private var pushedEntryIDs: Set<UUID> = []

    private struct Snapshot: Codable {
        var entries: [MemoryProfile]
        var keys: [String: UUID]
        /// 可选字段：老版本数据没有该键时解码为 nil，不破坏兼容
        var pushedEntryIDs: [UUID]?
    }

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        load()
    }

    // MARK: - 聚合

    /// 从本地对话重建档案：读取所有频道的最近对话，按规则分类后重建档案列表。
    /// 每次调用都会基于当前对话全量重建（已消失的对话对应档案自然消失，不保留过期数据）。
    func refreshFromConversations() {
        var groups: [String: GroupValue] = [:]

        for channel in ChannelStore.shared.channels {
            let messages = ConversationStore.shared.load(channelId: channel.id)
            for message in messages where message.role == .user {
                guard let classified = Self.classify(message.content) else { continue }
                let key = Self.aggregationKey(category: classified.category, keyword: classified.keyword)

                if let existing = groups[key], existing.date >= message.timestamp {
                    continue
                }
                groups[key] = GroupValue(
                    category: classified.category,
                    keyword: classified.keyword,
                    text: Self.summarize(message.content),
                    source: Self.sourceLabel(channel: channel),
                    date: message.timestamp
                )
            }
        }

        var rebuilt: [MemoryProfile] = []
        for (key, value) in groups {
            let entry = MemoryProfile(
                id: keys[key] ?? UUID(),
                title: Self.title(for: value.keyword, text: value.text),
                category: value.category,
                summary: value.text,
                source: value.source,
                lastUpdated: value.date
            )
            keys[key] = entry.id
            rebuilt.append(entry)
        }

        // 每类最多保留最近 30 条，总数上限 120（避免无限膨胀）
        let capped = Self.capped(rebuilt, perCategory: 30, total: 120)
        entries = capped
        save()
        profiles = Self.ordered(capped)
    }

    // MARK: - 分类规则

    /// 简单规则分类：偏好 -> 项目 -> 灵感 -> 事实（事实需为有一定长度的真实句子）。
    /// - 偏好：我喜欢/我不喜欢/习惯/偏好/讨厌/爱吃/爱喝 等明确个人好恶
    /// - 项目：项目/在做/开发/负责/打算/计划 等正在做或计划做的事
    /// - 灵感：灵感/点子/脑洞/突然想到/想法
    /// - 事实：其他含字母或数字、长度 >= 8 的句子
    static func classify(_ text: String) -> (category: MemoryProfile.Category, keyword: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isReadable(trimmed) else { return nil }

        if let keyword = Self.firstKeyword(in: trimmed, candidates: [
            "我不喜欢", "我不爱", "我喜欢", "我爱", "习惯", "偏好", "讨厌", "喜欢", "爱吃", "爱喝", "想喝", "想吃"
        ]) {
            return (.preference, keyword)
        }
        if let keyword = Self.firstKeyword(in: trimmed, candidates: [
            "项目", "正在做", "在做", "打算", "计划", "开发", "负责", "下一步"
        ]) {
            return (.project, keyword)
        }
        if let keyword = Self.firstKeyword(in: trimmed, candidates: [
            "灵感", "点子", "脑洞", "突然想到", "想法"
        ]) {
            return (.inspiration, keyword)
        }
        if trimmed.count >= 8 {
            return (.fact, "事实")
        }
        return nil
    }

    private static func firstKeyword(in text: String, candidates: [String]) -> String? {
        candidates.first { text.contains($0) }
    }

    /// 可读性检查：必须包含字母或数字（排除纯 emoji/标点/空白）。
    private static func isReadable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 摘要截断：超长文本保留前 120 字。
    private static func summarize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    /// 标题：取正文开头（最多 12 字），作为卡片标题。
    private static func title(for keyword: String, text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = String(trimmed.prefix(12))
        return head.count < trimmed.count ? head + "…" : head
    }

    private static func sourceLabel(channel: Channel) -> String {
        "手机 · \(channel.name)"
    }

    private static func aggregationKey(category: MemoryProfile.Category, keyword: String) -> String {
        "\(category.rawValue)|\(keyword)"
    }

    // MARK: - 排序与上限

    /// 分类展示顺序 + 组内按最近更新时间倒序。
    private static func ordered(_ entries: [MemoryProfile]) -> [MemoryProfile] {
        entries.sorted { lhs, rhs in
            let lhsIndex = MemoryProfile.Category.displayOrder.firstIndex(of: lhs.category) ?? 0
            let rhsIndex = MemoryProfile.Category.displayOrder.firstIndex(of: rhs.category) ?? 0
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.lastUpdated > rhs.lastUpdated
        }
    }

    private static func capped(_ entries: [MemoryProfile], perCategory: Int, total: Int) -> [MemoryProfile] {
        var kept: [MemoryProfile] = []
        var countByCategory: [MemoryProfile.Category: Int] = [:]
        for entry in entries.sorted(by: { $0.lastUpdated > $1.lastUpdated }) {
            let count = countByCategory[entry.category, default: 0]
            guard count < perCategory, kept.count < total else { continue }
            kept.append(entry)
            countByCategory[entry.category, default: 0] = count + 1
        }
        return kept
    }

    // MARK: - 外部写入（语音日记联动，第 4 层）

    /// 追加一条档案条目（如语音日记的灵感），不进入对话聚合池。
    /// key 带来源+条目 id 唯一后缀：每次写入都是独立条目，id 稳定，
    /// 不会与 refreshFromConversations 的聚合键合并。
    @discardableResult
    func addProfileEntry(
        category: MemoryProfile.Category,
        summary: String,
        source: String,
        date: Date = Date()
    ) -> MemoryProfile {
        let entry = MemoryProfile(
            id: UUID(),
            title: Self.title(for: category.rawValue, text: summary),
            category: category,
            summary: summary,
            source: source,
            lastUpdated: date
        )
        keys["\(category.rawValue)|\(source)|\(entry.id.uuidString)"] = entry.id
        entries.append(entry)
        save()
        profiles = Self.ordered(entries)
        // 外部写入也尝试沉淀到网关（未配置网关时静默跳过；失败本地保留）
        Task { await syncToGateway() }
        return entry
    }

    // MARK: - 网关沉淀（第 4 层）

    /// 最近沉淀：全部条目按更新时间倒序（供卡片「最近沉淀」滚动摘要）。
    var recentEntries: [MemoryProfile] {
        entries.sorted { $0.lastUpdated > $1.lastUpdated }
    }

    /// 今日新增条目数（卡片角标）：按 lastUpdated 是否落在今天统计。
    var todayAddedCount: Int {
        entries.filter { Calendar.current.isDateInToday($0.lastUpdated) }.count
    }

    /// 把尚未推送的 偏好/项目/灵感 条目写入网关记忆（memory_add）。
    /// - 失败静默：不抛错、不提示，本地档案保留，下次同步自动重试。
    /// - 事实类不推送，避免把普通聊天句子灌进智能体记忆。
    func syncToGateway() async {
        guard let settings, settings.isConfigured else { return }

        let candidates = entries.filter { entry in
            guard !pushedEntryIDs.contains(entry.id) else { return false }
            return entry.category == .preference
                || entry.category == .project
                || entry.category == .inspiration
        }
        guard !candidates.isEmpty else { return }

        let gatewayURL = settings.settings.gatewayURL
        let token = OpenClawClient.resolveHTTPToken(
            settingsToken: settings.gatewayToken,
            gatewayURL: gatewayURL
        )

        for entry in candidates {
            do {
                // memory_add 工具名与参数为假设（官方工具清单当前只有 memory_search/memory_get），
                // 待网关侧确认；content 尽量自包含，方便网关按文本沉淀。
                _ = try await client.invokeTool(
                    tool: "memory_add",
                    args: [
                        "content": .string(Self.gatewayContent(for: entry)),
                        "source": .string(entry.source),
                        "category": .string(entry.category.rawValue)
                    ],
                    gatewayURL: gatewayURL,
                    token: token
                )
                pushedEntryIDs.insert(entry.id)
            } catch {
                // 网关 memory_add 未部署/参数不符/网络失败：静默跳过，本地保留
            }
        }
        save()
    }

    /// 网关沉淀文本：分类 + 摘要 + 来源（内容自包含，便于网关直接记忆）。
    private static func gatewayContent(for entry: MemoryProfile) -> String {
        "【\(entry.category.rawValue)】\(entry.summary)\n来源：\(entry.source)"
    }

    // MARK: - 持久化

    private func load() {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        entries = snapshot.entries
        keys = snapshot.keys
        pushedEntryIDs = Set(snapshot.pushedEntryIDs ?? [])
        profiles = Self.ordered(entries)
    }

    private func save() {
        let snapshot = Snapshot(
            entries: entries,
            keys: keys,
            pushedEntryIDs: Array(pushedEntryIDs)
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }

    private struct GroupValue {
        var category: MemoryProfile.Category
        var keyword: String
        var text: String
        var source: String
        var date: Date
    }
}