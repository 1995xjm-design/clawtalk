import Foundation

/// 健康周报：近 7 天（含今天）健康总结。
///
/// 诚实原则：
/// - 健康权限未开 / 设备不支持 / 读取失败 → `steps` 为空数组、`totalSteps`/`avgSteps` 为 nil，
///   `insights` 不编造数字，页面展示引导与空态。
/// - 提醒 / 日记未接入或暂无数据 → 对应字段为 nil，页面如实标注「未接入 / 暂无」。
/// - 提醒没有历史触发记录接口，按排程（repeatType + 日期）统计本周「预计触发」次数，
///   文案与字段名均如实标注，不冒充已触发记录。
struct HealthReport: Identifiable, Codable, Equatable {

    let id: UUID
    /// 周起始日（近 7 天窗口第一天，自然日零点）
    let weekStart: Date
    /// 周结束日（今天，自然日零点）
    let weekEnd: Date
    /// 每日步数（自然日升序，最后一项为今天；无数据时为空数组）
    let steps: [Int]
    /// 日均步数（有逐日数据时才有）
    let avgSteps: Int?
    /// 本周总步数（逐日数据缺失但 HealthCapability 汇总可用时取汇总；两者皆无则 nil）
    let totalSteps: Int?
    /// 日目标步数（默认 6000，后续可在设置页调整）
    let targetSteps: Int
    /// 达标天数（steps 中 >= targetSteps 的天数；无步数数据时为 0）
    let goalDays: Int
    /// 本周语音日记条数（日记未接入时为 nil）
    let diaryCount: Int?
    /// 本周提醒触发次数（按排程预计；提醒未接入时为 nil）
    let reminderTriggerCount: Int?
    /// 数据源跳过说明（权限未开 / 未接入 / 读取失败等，页面如实展示）
    let skippedNotes: [String]
    /// 洞察文案（诚实生成；无步数数据时只保留提醒 / 日记等真实条目）
    let insights: [String]
    /// 报告日期（= weekEnd）
    let reportDate: Date
    /// 生成时间（卡片 / 周报页 .task 触发时刻）
    let generatedAt: Date

    init(
        id: UUID = UUID(),
        weekStart: Date,
        weekEnd: Date,
        steps: [Int],
        avgSteps: Int?,
        totalSteps: Int?,
        targetSteps: Int,
        goalDays: Int,
        diaryCount: Int?,
        reminderTriggerCount: Int?,
        skippedNotes: [String],
        insights: [String],
        reportDate: Date,
        generatedAt: Date
    ) {
        self.id = id
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.steps = steps
        self.avgSteps = avgSteps
        self.totalSteps = totalSteps
        self.targetSteps = targetSteps
        self.goalDays = goalDays
        self.diaryCount = diaryCount
        self.reminderTriggerCount = reminderTriggerCount
        self.skippedNotes = skippedNotes
        self.insights = insights
        self.reportDate = reportDate
        self.generatedAt = generatedAt
    }

    // MARK: - 派生

    /// 是否有真实逐日步数数据
    var hasStepsData: Bool { !steps.isEmpty }

    /// 与 steps 一一对应的日期（自然日升序；steps 为空时为空数组）
    var dayDates: [Date] {
        guard !steps.isEmpty else { return [] }
        let calendar = Calendar.current
        var dates: [Date] = []
        dates.reserveCapacity(steps.count)
        for index in 0..<steps.count {
            let date = calendar.date(byAdding: .day, value: index, to: weekStart) ?? weekStart
            dates.append(date)
        }
        return dates
    }

    /// 达标率 0...1（无逐日数据为 nil）
    var goalRate: Double? {
        guard !steps.isEmpty else { return nil }
        return Double(goalDays) / Double(steps.count)
    }

    /// 周报周期文案（如「8月6日 – 8月12日」）
    var periodText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return "\(formatter.string(from: weekStart)) – \(formatter.string(from: weekEnd))"
    }

    /// 生成时间文案（如「8月12日 20:30」）
    var generatedTimeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: generatedAt)
    }

    /// 语音朗读 / 分享用完整文案：与页面展示一致，诚实不编数据。
    var spokenText: String {
        var parts: [String] = ["健康周报，\(periodText)"]
        if hasStepsData {
            parts.append("本周共走 \(totalSteps ?? 0) 步")
        } else {
            parts.append("本周暂无步数数据")
        }
        parts.append(contentsOf: insights)
        parts.append(contentsOf: skippedNotes)
        parts.append("周报生成时间 \(generatedTimeText)")
        return parts.joined(separator: "。") + "。"
    }
}
