import Foundation

/// 记忆 → App Group 共享（键盘扩展 AI 面板读取；电脑关机后仍可用本地分层记忆 + 最后缓存快照）。
enum MemoryAppGroupSync {
    static let appGroupID = "group.7518554"
    private static let layersKey = "memory_layers_summary"
    private static let computerKey = "memory_computer_summary"
    private static let countKey = "memory_profile_count"

    /// 推送本地 L1/L2/L3 分层记忆（保留已有的电脑快照，互不覆盖）。
    static func pushLayers(entries: [MemoryProfile]) {
        guard let group = UserDefaults(suiteName: appGroupID) else { return }
        let existing = group.string(forKey: computerKey) ?? ""
        group.set(layeredSummary(entries: entries) ?? "", forKey: layersKey)
        group.set(existing, forKey: computerKey)
        group.set(entries.count, forKey: countKey)
        group.synchronize()
    }

    /// 推送电脑记忆快照摘要（保留已有的分层记忆）。
    static func pushComputerSummary(_ summary: String?) {
        guard let group = UserDefaults(suiteName: appGroupID) else { return }
        group.set(summary ?? "", forKey: computerKey)
        group.synchronize()
    }

    /// L1（近 7 天）→ L2（每周汇总）→ L3（长期档案）分层摘要；无数据返回 nil（诚实降级）。
    static func layeredSummary(entries: [MemoryProfile]) -> String? {
        let calendar = Calendar.current
        let now = Date()
        let cutoff = calendar.date(byAdding: .day, value: -7, to: now) ?? now
        let l1 = entries.filter { $0.lastUpdated >= cutoff }

        var parts: [String] = []
        if !l1.isEmpty {
            parts.append("【L1 近期】\n" + l1.prefix(10).map { "· \($0.summary)" }.joined(separator: "\n"))
        }

        let grouped = Dictionary(grouping: entries) { entry -> DateComponents in
            calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: entry.lastUpdated)
        }
        let weeks = grouped.keys.sorted { a, b in
            guard let da = calendar.date(from: a), let db = calendar.date(from: b) else { return false }
            return da < db
        }
        if !weeks.isEmpty {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let lines = weeks.compactMap { key -> String? in
                guard let start = calendar.date(from: key) else { return nil }
                let items = grouped[key] ?? []
                let titles = items.prefix(6).map(\.title).joined(separator: "、")
                return "\(formatter.string(from: start)) 周：\(items.count) 条（\(titles)）"
            }
            parts.append("【L2 每周汇总】\n" + lines.joined(separator: "\n"))
        }

        if !entries.isEmpty {
            parts.append("【L3 长期档案】\n" + entries.prefix(20).map { "【\($0.category.rawValue)】\($0.summary)" }.joined(separator: "\n"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
}
