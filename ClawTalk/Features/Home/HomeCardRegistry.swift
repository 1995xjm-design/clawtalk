import SwiftUI

/// 主页可配置卡片种类（D3：长按移除 / 工具页添加）。
/// 语音助手大卡常驻顶部；以下 7 张为可配置卡。
enum HomeCardKind: String, CaseIterable, Identifiable {
    case record
    case reminders
    case health
    case report
    case expense
    case travel
    case knowledge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .record: return "记录"
        case .reminders: return "提醒"
        case .health: return "健康"
        case .report: return "报告"
        case .expense: return "记账"
        case .travel: return "出行"
        case .knowledge: return "知识"
        }
    }

    var icon: String {
        switch self {
        case .record: return "square.and.pencil"
        case .reminders: return "bell.badge.fill"
        case .health: return "heart.fill"
        case .report: return "doc.text.fill"
        case .expense: return "yensign.circle.fill"
        case .travel: return "airplane"
        case .knowledge: return "books.vertical.fill"
        }
    }

    var tint: Color {
        switch self {
        case .record: return .teal
        case .reminders: return .orange
        case .health: return .green
        case .report: return .indigo
        case .expense: return .green
        case .travel: return .blue
        case .knowledge: return .purple
        }
    }

    var summary: String {
        switch self {
        case .record: return "语音日记 · 捕捉 · 口述 · 写作 · 会议"
        case .reminders: return "提醒 · 纪念日 · 到家离开"
        case .health: return "健康 · 习惯打卡 · 健康周报"
        case .report: return "每日播报 · 周报月报 · 主动建议"
        case .expense: return "语音记账 · 本月收支 · 分类"
        case .travel: return "差旅管家 · 停车位置"
        case .knowledge: return "知识库问答 · 长文摘要"
        }
    }
}

/// 主页卡片配置注册表：AppStorage 持久化（key `home.enabledCardKinds`，逗号分隔 rawValue）。
/// - 主页：长按卡片 →「从主页移除」写回本 key；
/// - 工具页：将来「添加到主页」通过 `HomeCardRegistry.setEnabledKinds(...)` 写同一 key。
enum HomeCardRegistry {
    static let storageKey = "home.enabledCardKinds"
    static let allKinds = HomeCardKind.allCases
    static let defaultStorageValue = allKinds.map(\.rawValue).joined(separator: ",")

    static func enabledKinds(from storage: String) -> [HomeCardKind] {
        let stored = Set(storage.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        return allKinds.filter { stored.contains($0.rawValue) }
    }

    static func storageValue(for kinds: [HomeCardKind]) -> String {
        kinds.map(\.rawValue).joined(separator: ",")
    }

    static func removing(_ kind: HomeCardKind, from storage: String) -> String {
        var set = Set(storage.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        set.remove(kind.rawValue)
        return allKinds.filter { set.contains($0.rawValue) }.map(\.rawValue).joined(separator: ",")
    }

    /// 工具页「添加到主页」接入点：写回同一 UserDefaults key。
    static func setEnabledKinds(_ kinds: [HomeCardKind]) {
        UserDefaults.standard.set(storageValue(for: kinds), forKey: storageKey)
    }
}
