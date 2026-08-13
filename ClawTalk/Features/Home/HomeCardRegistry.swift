import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// 主页可配置卡片种类（D3：长按移除 / 工具页添加；S10：新增「我的记忆」并支持拖动排序、尺寸调整）。
/// 语音助手大卡常驻顶部（固定大卡）；以下 8 张为可配置卡（含「我的记忆」）。
enum HomeCardKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case memory
    case cloneTalk
    case record
    case reminders
    case health
    case report
    case expense
    case travel
    case knowledge
    case keyboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: return "我的记忆"
        case .cloneTalk: return "AI 分身"
        case .record: return "记录"
        case .reminders: return "提醒"
        case .health: return "健康"
        case .report: return "报告"
        case .expense: return "记账"
        case .travel: return "出行"
        case .knowledge: return "知识"
        case .keyboard: return "键盘智能"
        }
    }

    var icon: String {
        switch self {
        case .memory: return "brain.head.profile"
        case .cloneTalk: return "person.crop.circle.badge.clock"
        case .record: return "square.and.pencil"
        case .reminders: return "bell.badge.fill"
        case .health: return "heart.fill"
        case .report: return "doc.text.fill"
        case .expense: return "yensign.circle.fill"
        case .travel: return "airplane"
        case .knowledge: return "books.vertical.fill"
        case .keyboard: return "keyboard.badge.ellipsis"
        }
    }

    var tint: Color {
        switch self {
        case .memory: return .purple
        case .cloneTalk: return .pink
        case .record: return .teal
        case .reminders: return .orange
        case .health: return .green
        case .report: return .indigo
        case .expense: return .green
        case .travel: return .blue
        case .knowledge: return .purple
        case .keyboard: return .indigo
        }
    }

    var summary: String {
        switch self {
        case .memory: return "个人档案 · 对话沉淀 · 记忆搜索"
        case .cloneTalk: return "以你的口吻生成回复草稿"
        case .record: return "语音日记 · 口述 · 写作 · 会议"
        case .reminders: return "提醒 · 纪念日 · 到家离开"
        case .health: return "健康 · 习惯打卡 · 健康周报"
        case .report: return "每日播报 · 周报月报 · 主动建议"
        case .expense: return "语音记账 · 本月收支 · 分类"
        case .travel: return "差旅管家 · 停车位置"
        case .knowledge: return "知识库问答 · 长文摘要"
        case .keyboard: return "Now ClawTalk · 每日洞察 · 智能调频 · 聊天档案"
        }
    }

    /// S10：卡片默认尺寸（语音助手大卡固定大卡，不在本枚举内）。
    /// 明哥要求：主页小卡全部换成中卡——所有可配置卡默认 medium。
    var defaultSize: HomeCardSize {
        .medium
    }
}

/// S10：卡片尺寸（对齐 iOS 桌面小组件比例）。
/// - small：1 列（约 1/4 屏宽）；medium：2 列（约 1/2 屏宽）；large：4 列（整行）。
enum HomeCardSize: String, CaseIterable, Codable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var gridColumns: Int {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .large: return 4
        }
    }

    /// 编辑态尺寸按钮循环：中 → 大 → 中（small 已废弃，一行 2 个起）。
    var next: HomeCardSize {
        switch self {
        case .small: return .medium
        case .medium: return .large
        case .large: return .medium
        }
    }

    var shortName: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
}

extension HomeCardKind: Transferable {
    /// 拖动排序：卡片自身作为拖拽负载（CodableRepresentation 编码为 JSON 文本）。
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .text)
    }
}

/// 主页卡片配置注册表：AppStorage 持久化。
/// - 启用与顺序：key `home.enabledCardKinds`（逗号分隔 rawValue，**顺序即主页排布顺序**，支持拖动排序）；
/// - 尺寸：key `home.cardSizes`（`kind:size,kind:size`）。
enum HomeCardRegistry {
    static let storageKey = "home.enabledCardKinds"
    static let sizeStorageKey = "home.cardSizes"
    static let allKinds = HomeCardKind.allCases
    static let defaultStorageValue = allKinds.map(\.rawValue).joined(separator: ",")

    /// 解析启用的卡片：**按存储顺序返回**（S10 拖动排序持久化依赖此顺序）。
    static func enabledKinds(from storage: String) -> [HomeCardKind] {
        storage.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap { HomeCardKind(rawValue: $0) }
    }

    static func storageValue(for kinds: [HomeCardKind]) -> String {
        kinds.map(\.rawValue).joined(separator: ",")
    }

    static func removing(_ kind: HomeCardKind, from storage: String) -> String {
        var list = enabledKinds(from: storage)
        list.removeAll { $0 == kind }
        return storageValue(for: list)
    }

    /// S10：把拖拽的卡片移到目标卡片之前（保持其余顺序）。
    static func moving(_ source: HomeCardKind, before target: HomeCardKind, in storage: String) -> String {
        var list = enabledKinds(from: storage)
        guard let from = list.firstIndex(of: source),
              let to = list.firstIndex(of: target),
              from != to else {
            return storage
        }
        list.remove(at: from)
        let targetIndex = list.firstIndex(of: target) ?? list.count
        list.insert(source, at: targetIndex)
        return storageValue(for: list)
    }

    /// S10：读取卡片尺寸（未设置时回落默认尺寸）。
    static func size(for kind: HomeCardKind, storage: String) -> HomeCardSize {
        for part in storage.split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, let key = HomeCardKind(rawValue: kv[0]), key == kind,
               let value = HomeCardSize(rawValue: kv[1]) {
                // 明哥要求：一行 2 个（small 一律升 medium，老存档迁移）
                return value == .small ? .medium : value
            }
        }
        return kind.defaultSize
    }

    /// S10：写入卡片尺寸（覆盖同卡旧值）。
    static func settingSize(_ size: HomeCardSize, for kind: HomeCardKind, in storage: String) -> String {
        var entries = storage.split(separator: ",").map(String.init)
        entries.removeAll { $0.hasPrefix(kind.rawValue + ":") }
        entries.append("\(kind.rawValue):\(size.rawValue)")
        return entries.joined(separator: ",")
    }

    /// 工具页「添加到主页」接入点：写回同一 UserDefaults key。
    static func setEnabledKinds(_ kinds: [HomeCardKind]) {
        UserDefaults.standard.set(storageValue(for: kinds), forKey: storageKey)
    }

    /// S10：一次性迁移——老用户存储中无「我的记忆」时，插入到最前（今日概览下方第一格）。
    static func migrateMemoryCardIfNeeded(_ storage: inout String) {
        let migratedKey = "home.cardsMigratedMemoryV1"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)
        var kinds = enabledKinds(from: storage)
        if !kinds.contains(.memory) {
            kinds.insert(.memory, at: 0)
            storage = storageValue(for: kinds)
        }
    }

    /// 一次性迁移：老用户存储无「AI 分身」时插到记忆卡之后。
    static func migrateCloneTalkCardIfNeeded(_ storage: inout String) {
        let migratedKey = "home.cardsMigratedCloneTalkV1"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)
        var kinds = enabledKinds(from: storage)
        if !kinds.contains(.cloneTalk) {
            if let memIdx = kinds.firstIndex(of: .memory) {
                kinds.insert(.cloneTalk, at: memIdx + 1)
            } else {
                kinds.append(.cloneTalk)
            }
            storage = storageValue(for: kinds)
        }
    }

    /// 统一迁移入口：主页读取卡片存储时调用。
    static func runMigrations(_ storage: inout String) {
        migrateMemoryCardIfNeeded(&storage)
        migrateCloneTalkCardIfNeeded(&storage)
    }
}