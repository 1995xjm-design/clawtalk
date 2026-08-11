import Foundation

/// 本地档案存储：UserDefaults JSON 持久化 + 从本地对话按简单规则聚合。
/// 诚实原则：只聚合真实存在的本地对话；没有数据时 profiles 为空数组，由界面展示空状态，不造假。
@Observable
final class MemoryProfileStore {
    /// 当前档案条目（按分类顺序 + 最近更新时间排序），供界面直接展示。
    private(set) var profiles: [MemoryProfile] = []

    private let defaults = UserDefaults.standard
    private let snapshotKey = "memory_hub_profiles_v1"

    private var entries: [MemoryProfile] = []
    /// 聚合键（分类|关键词）-> 条目 id：多次聚合时同一来源条目 id 保持稳定，避免列表抖动。
    private var keys: [String: UUID] = [:]

    private struct Snapshot: Codable {
        var entries: [MemoryProfile]
        var keys: [String: UUID]
    }

    init() {
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

    // MARK: - 持久化

    private func load() {
        guard let data = defaults.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        entries = snapshot.entries
        keys = snapshot.keys
        profiles = Self.ordered(entries)
    }

    private func save() {
        let snapshot = Snapshot(entries: entries, keys: keys)
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
