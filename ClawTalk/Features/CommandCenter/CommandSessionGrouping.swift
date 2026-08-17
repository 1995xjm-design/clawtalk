import Foundation

/// 会话中心分组（对齐官方 CommandSessionGrouping）：
/// 按固定分组（置顶/分类/未分组）聚合会话列表。
struct CommandSessionSection: Identifiable {
    enum ID: Hashable {
        case pinned
        case category(String)
        case ungrouped
    }

    let id: ID
    let title: String
    let entries: [SessionEntry]
    let showsHeader: Bool
}

enum CommandSessionGrouping {
    static func sections(from entries: [SessionEntry], knownGroups: [String] = []) -> [CommandSessionSection] {
        let pinned = sortedByActivity(entries.filter { $0.channel == "pinned" })
        let unpinned = entries.filter { $0.channel != "pinned" }
        let categoryNames = Set(unpinned.compactMap { normalizedCategory($0.channel) })
            .union(knownGroups.compactMap(normalizedCategory))
            .sorted(by: categoryComesBefore)
        var sections: [CommandSessionSection] = []

        if !pinned.isEmpty {
            sections.append(CommandSessionSection(id: .pinned, title: "置顶", entries: pinned, showsHeader: true))
        }
        for category in categoryNames {
            let categoryEntries = unpinned.filter { normalizedCategory($0.channel) == category }
            sections.append(CommandSessionSection(
                id: .category(category),
                title: category,
                entries: sortedByActivity(categoryEntries),
                showsHeader: true))
        }
        let ungrouped = sortedByActivity(unpinned.filter { normalizedCategory($0.channel) == nil })
        if !ungrouped.isEmpty {
            sections.append(CommandSessionSection(
                id: .ungrouped,
                title: "未分组",
                entries: ungrouped,
                showsHeader: !categoryNames.isEmpty))
        }
        return sections
    }

    static func previewOrder(_ entries: [SessionEntry]) -> [SessionEntry] {
        entries.sorted { lhs, rhs in
            if (lhs.channel == "pinned") != (rhs.channel == "pinned") {
                return lhs.channel == "pinned"
            }
            let left = activityTimestamp(lhs)
            let right = activityTimestamp(rhs)
            return left == right ? lhs.key < rhs.key : left > right
        }
    }

    static func previewSelection(_ entries: [SessionEntry], currentKey: String, limit: Int = 3) -> [SessionEntry] {
        let ordered = previewOrder(entries)
        let capped = Array(ordered.prefix(limit))
        guard !currentKey.isEmpty,
              !capped.contains(where: { $0.key == currentKey })
        else { return capped }
        guard let current = ordered.first(where: { $0.key == currentKey }) else { return capped }
        return [current] + capped
    }

    static func categories(from entries: [SessionEntry]) -> [String] {
        Array(Set(entries.compactMap { normalizedCategory($0.channel) })).sorted(by: categoryComesBefore)
    }

    static func members(_ entries: [SessionEntry], in category: String) -> [SessionEntry] {
        sortedByActivity(entries.filter { normalizedCategory($0.channel) == category })
    }

    static func activityTimestamp(_ entry: SessionEntry) -> Double {
        entry.updatedAt ?? 0
    }

    private static func sortedByActivity(_ entries: [SessionEntry]) -> [SessionEntry] {
        entries.sorted { lhs, rhs in
            let left = activityTimestamp(lhs)
            let right = activityTimestamp(rhs)
            return left == right ? lhs.key < rhs.key : left > right
        }
    }

    private static func normalizedCategory(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "default" ? nil : trimmed
    }

    private static func categoryComesBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }
}
