import Foundation

/// 报告周期：周报 / 月报。
enum ReportPeriod: String, Codable, CaseIterable, Identifiable, Equatable {
    case week = "week"
    case month = "month"

    var id: String { rawValue }

    /// 展示名称（周报 / 月报）。
    var displayName: String {
        switch self {
        case .week: return "周报"
        case .month: return "月报"
        }
    }
}

/// 报告分区：一个数据源（日记/健康/习惯/记账/待办/记忆）的汇总内容。
///
/// 诚实约定（不造假）：
/// - `content` 为空数组 = 该分区「无数据」，页面显示「无数据」空态；
/// - `skippedReason` 非 nil = 数据源未接入 / 未授权 / 读取失败，页面显示跳过原因；
/// - 有数据源但统计为 0 时，`content` 放「本周期暂无 XX」这类真实零值语句。
struct ReportSection: Identifiable, Codable, Equatable {
    /// 稳定分区键（diary / health / habits / expense / todos / memory）。
    let id: String
    /// 分区标题（如「语音日记」）。
    let title: String
    /// 分区内容行（每行一句，页面逐行展示）。
    let content: [String]
    /// 数据源跳过原因（未接入 / 未授权 / 读取失败）；nil = 数据源正常。
    let skippedReason: String?

    init(
        id: String,
        title: String,
        content: [String],
        skippedReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.skippedReason = skippedReason
    }
}

/// 周期报告：自动汇总一周/一月的活动（日记/健康/习惯/记账/待办/记忆），
/// 生成可分享、可朗读的报告文本。
struct PeriodReport: Identifiable, Codable, Equatable {
    let id: UUID
    /// 周期类型：周报 / 月报。
    let period: ReportPeriod
    /// 区间首日（自然日零点）。
    let startDate: Date
    /// 区间末日（自然日零点；月报 = 本月 1 号到今天，月末未到不预填未来）。
    let endDate: Date
    /// 各数据源分区。
    let sections: [ReportSection]
    /// 一句话总结（中性，不编造具体数字）。
    let summary: String
    /// 生成时间。
    let generatedAt: Date

    init(
        id: UUID = UUID(),
        period: ReportPeriod,
        startDate: Date,
        endDate: Date,
        sections: [ReportSection],
        summary: String,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.period = period
        self.startDate = startDate
        self.endDate = endDate
        self.sections = sections
        self.summary = summary
        self.generatedAt = generatedAt
    }

    // MARK: - 派生文案

    /// 周期范围文案（如「8月6日 – 8月12日」）。
    var periodText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }

    /// 生成时间文案（如「8月12日 20:30」）。
    var generatedTimeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: generatedAt)
    }

    /// 语音朗读 / 分享用的完整报告文本（与页面分区一致，诚实不编造）。
    var spokenText: String {
        var parts: [String] = ["\(period.displayName)：\(periodText)"]
        parts.append(summary)
        for section in sections {
            var lines: [String] = [section.title]
            if !section.content.isEmpty {
                lines.append(contentsOf: section.content)
            } else if let reason = section.skippedReason {
                lines.append(reason)
            } else {
                lines.append("暂无数据")
            }
            parts.append(lines.joined(separator: "："))
        }
        parts.append("报告生成于 \(generatedTimeText)")
        return parts.joined(separator: "。") + "。"
    }

    /// 分享用文本：标题 + 总结 + 各分区明细 + 生成时间。
    var sharedText: String {
        var lines: [String] = ["\(period.displayName) \(periodText)"]
        lines.append(summary)
        for section in sections {
            lines.append("【\(section.title)】")
            if !section.content.isEmpty {
                lines.append(contentsOf: section.content)
            } else if let reason = section.skippedReason {
                lines.append(reason)
            } else {
                lines.append("暂无数据")
            }
        }
        lines.append("生成时间：\(generatedTimeText)")
        return lines.joined(separator: "\n")
    }
}
