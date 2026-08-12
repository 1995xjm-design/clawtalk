import Foundation
import EventKit

/// 周报/月报生成器：聚合 日记 / 健康 / 习惯 / 记账 / 待办 / 记忆 六类数据，
/// 生成 PeriodReport（可分享、可朗读）。
///
/// 诚实原则（不造假）：
/// - 每个数据源独立读取；未注入 / 未授权 / 读取失败 → 分区 `content` 为空、
///   `skippedReason` 写明原因，页面如实展示。
/// - 有数据源但统计为 0 → 如实写「本周期暂无 XX」。
/// - summary 为中性总结，不编造具体数字。
///
/// 区间规则：
/// - 周报：近 7 天（含今天，与健康周报一致）。
/// - 月报：本月 1 号到今天（月末未到不预填未来）。
///
/// 使用（主智能体接线）：
/// ```swift
/// let generator = ReportGenerator(
///     diaryViewModel: diaryViewModel,       // 可选
///     habitStore: habitStore,               // 可选
///     expenseStore: expenseStore,           // 可选
///     memoryProfileStore: memoryProfileStore // 可选
/// )
/// let report = await generator.generate(period: .week)
/// ```
@MainActor
struct ReportGenerator {

    private let diaryViewModel: VoiceDiaryViewModel?
    private let healthReportGenerator: HealthReportGenerator?
    private let habitStore: HabitStore?
    private let expenseStore: ExpenseStore?
    private let memoryProfileStore: MemoryProfileStore?
    private let now: Date

    init(
        diaryViewModel: VoiceDiaryViewModel? = nil,
        healthReportGenerator: HealthReportGenerator? = nil,
        habitStore: HabitStore? = nil,
        expenseStore: ExpenseStore? = nil,
        memoryProfileStore: MemoryProfileStore? = nil,
        now: Date = Date()
    ) {
        self.diaryViewModel = diaryViewModel
        self.healthReportGenerator = healthReportGenerator
        self.habitStore = habitStore
        self.expenseStore = expenseStore
        self.memoryProfileStore = memoryProfileStore
        self.now = now
    }

    // MARK: - 生成

    /// 生成指定周期报告；各数据源独立降级，永不 throw。
    func generate(period: ReportPeriod) async -> PeriodReport {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let (start, end) = Self.range(for: period, calendar: calendar, todayStart: todayStart)
        guard let endExclusive = calendar.date(byAdding: .day, value: 1, to: end) else {
            // 极端兜底（正常不会发生）：直接按今天生成空报告
            return PeriodReport(
                period: period,
                startDate: todayStart,
                endDate: todayStart,
                sections: [],
                summary: "区间计算失败，请稍后重试",
                generatedAt: now
            )
        }
        let range = start..<endExclusive

        let diary = diarySection(in: range)
        let health = await healthSection(for: period, in: range)
        let habits = habitSection(in: range)
        let expense = expenseSection(in: range)
        let todos = await todoSection(in: range)
        let memory = memorySection(in: range)

        let sections: [ReportSection] = [
            ReportSection(id: "diary", title: "语音日记", content: diary.content, skippedReason: diary.skipReason),
            ReportSection(id: "health", title: "健康步数", content: health.content, skippedReason: health.skipReason),
            ReportSection(id: "habits", title: "习惯打卡", content: habits.content, skippedReason: habits.skipReason),
            ReportSection(id: "expense", title: "记账", content: expense.content, skippedReason: expense.skipReason),
            ReportSection(id: "todos", title: "待办", content: todos.content, skippedReason: todos.skipReason),
            ReportSection(id: "memory", title: "记忆档案", content: memory.content, skippedReason: memory.skipReason)
        ]

        let dataCount = [diary, health, habits, expense, todos, memory].filter(\.hasData).count
        let summary = Self.summary(for: period, dataSectionCount: dataCount)

        return PeriodReport(
            period: period,
            startDate: start,
            endDate: end,
            sections: sections,
            summary: summary,
            generatedAt: now
        )
    }

    // MARK: - 区间

    /// 周报：近 7 天（含今天）；月报：本月 1 号到今天（月末未到不预填未来）。
    private static func range(
        for period: ReportPeriod,
        calendar: Calendar,
        todayStart: Date
    ) -> (start: Date, end: Date) {
        switch period {
        case .week:
            let start = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
            return (start, todayStart)
        case .month:
            let start = calendar.date(
                from: calendar.dateComponents([.year, .month], from: todayStart)
            ) ?? todayStart
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: start),
                  let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
                return (start, todayStart)
            }
            return (start, min(monthEnd, todayStart))
        }
    }

    // MARK: - 日记

    /// 日记：区间内条数 + 最近主题（按时间倒序前 3 条摘要）。
    private func diarySection(in range: Range<Date>) -> SectionResult {
        guard let diaryViewModel else {
            return SectionResult(skipReason: "日记数据未接入，本周期日记已跳过")
        }
        let entries = diaryViewModel.entries.filter { range.contains($0.date) }
        guard !entries.isEmpty else {
            return SectionResult(content: ["本周期暂无语音日记"])
        }
        var lines = ["本周期共记 \(entries.count) 篇语音日记"]
        let recent = entries.sorted { $0.date > $1.date }.prefix(3)
        for entry in recent {
            lines.append(Self.summarize(entry.text))
        }
        return SectionResult(content: lines, hasData: true)
    }

    // MARK: - 健康

    /// 步数：周报复用 HealthReportGenerator（近 7 天窗口，含逐日/达标数据）；
    /// 月报用 HealthCapability.steps(days: 31) 读近 31 天总量（诚实标注为近 31 天，非自然月）。
    private func healthSection(
        for period: ReportPeriod,
        in range: Range<Date>
    ) async -> SectionResult {
        switch period {
        case .week:
            let generator = healthReportGenerator ?? HealthReportGenerator(now: now)
            let report = await generator.generate()
            if report.hasStepsData {
                var lines = ["本周共走 \(report.totalSteps ?? 0) 步，日均约 \(report.avgSteps ?? 0) 步"]
                if report.goalDays > 0 {
                    lines.append("\(report.goalDays)/\(report.steps.count) 天达到 \(report.targetSteps) 步目标")
                }
                return SectionResult(content: lines, hasData: true)
            }
            if let total = report.totalSteps {
                return SectionResult(content: ["本周共走 \(total) 步（逐日明细不可用）"], hasData: true)
            }
            let note = report.skippedNotes.first ?? "健康数据为空，暂无步数"
            return SectionResult(skipReason: note)
        case .month:
            do {
                let result = try await HealthCapability.steps(days: 31)
                let avg = result.steps / 31
                let line = "近 31 天共走 \(result.steps) 步，日均约 \(avg) 步（统计窗口为最近 31 天，非自然月）"
                return SectionResult(content: [line], hasData: result.steps > 0)
            } catch let error as HealthCapability.HealthError {
                return SectionResult(skipReason: Self.healthSkipMessage(for: error))
            } catch {
                return SectionResult(skipReason: "健康数据读取失败，步数已跳过")
            }
        }
    }

    private static func healthSkipMessage(for error: HealthCapability.HealthError) -> String {
        switch error {
        case .denied:
            return "健康数据权限未开启，步数已跳过（请在设置-健康中开启步数读取权限）"
        case .unavailable:
            return "此设备不支持健康数据，步数已跳过"
        case .failed(let message):
            return "健康数据读取失败，步数已跳过（\(message)）"
        }
    }

    // MARK: - 习惯

    /// 完成率 = 区间内实际打卡次数 / 应打卡次数
    /// （应打卡 = 各习惯 repeatDays 在区间内的安排日；实际打卡只统计应打卡日的打卡，与今日统计口径一致）。
    private func habitSection(in range: Range<Date>) -> SectionResult {
        guard let habitStore else {
            return SectionResult(skipReason: "习惯数据未接入，本周期习惯已跳过")
        }
        let habits = habitStore.habits
        guard !habits.isEmpty else {
            return SectionResult(content: ["暂无习惯，完成率未统计"])
        }

        var dueCount = 0
        var checkedCount = 0
        for habit in habits {
            dueCount += Self.dueDayCount(for: habit, in: range)
            checkedCount += Self.checkedDayCount(for: habit, in: range)
        }
        guard dueCount > 0 else {
            return SectionResult(content: ["本周期无应打卡日（习惯的重复日都不在区间内）"])
        }

        let rate = Int((Double(checkedCount) / Double(dueCount) * 100).rounded())
        let line = "习惯完成率 \(rate)%（应打卡 \(dueCount) 次 / 实际打卡 \(checkedCount) 次）"
        return SectionResult(content: [line], hasData: checkedCount > 0)
    }

    /// 区间内应打卡天数（按日迭代，防溢出）。
    private static func dueDayCount(for habit: Habit, in range: Range<Date>) -> Int {
        let calendar = Calendar.current
        var count = 0
        var day = calendar.startOfDay(for: range.lowerBound)
        while day < range.upperBound {
            if habit.isDue(on: day) { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return count
    }

    /// 区间内实际打卡天数（只统计应打卡日的打卡）。
    private static func checkedDayCount(for habit: Habit, in range: Range<Date>) -> Int {
        habit.checkIns.filter { key, _ in
            guard let date = Self.parseDateKey(key) else { return false }
            return range.contains(date) && habit.isDue(on: date)
        }.count
    }

    private static func parseDateKey(_ key: String) -> Date? {
        dateKeyParser.date(from: key)
    }

    private static let dateKeyParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - 记账

    /// 区间支出/收入/结余：直接用 ExpenseStore.entries 按日期区间统计（比月粒度更精确）。
    private func expenseSection(in range: Range<Date>) -> SectionResult {
        guard let expenseStore else {
            return SectionResult(skipReason: "记账数据未接入，本周期记账已跳过")
        }
        let entries = expenseStore.entries.filter { range.contains($0.date) }
        guard !entries.isEmpty else {
            return SectionResult(content: ["本周期暂无记账"])
        }

        var income = 0.0
        var expense = 0.0
        for entry in entries {
            switch entry.type {
            case .income: income += entry.amount
            case .expense: expense += entry.amount
            }
        }
        let balance = income - expense
        let lines = [
            "支出 \(expense.expenseAmountText) 元",
            "收入 \(income.expenseAmountText) 元",
            "结余 \(balance.expenseAmountText) 元"
        ]
        return SectionResult(content: lines, hasData: true)
    }

    // MARK: - 待办

    /// 待办完成数：优先 RemindersCapability（已完成列表，按截止日期落在区间内统计，
    /// 完成时间记录不可用 → 如实标注）；提醒事项未授权时降级统计「日记待办」。
    private func todoSection(in range: Range<Date>) async -> SectionResult {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess || status == .authorized {
            do {
                let completed = try await RemindersCapability.list(completed: true, limit: 500)
                let inRange = completed.filter { item in
                    guard let dueText = item.dueDate,
                          let due = Self.isoFormatter.date(from: dueText) else { return false }
                    return range.contains(due)
                }
                guard !inRange.isEmpty else {
                    return SectionResult(content: ["本周期暂无已完成待办"])
                }
                let line = "本周期已完成待办 \(inRange.count) 件（按截止日期统计，完成时间记录暂不可用）"
                return SectionResult(content: [line], hasData: true)
            } catch {
                return SectionResult(
                    skipReason: "待办读取失败，本周期待办已跳过（\(AppErrorText.localized(error.localizedDescription))）"
                )
            }
        }

        // 提醒事项未授权：降级到日记待办
        guard let diaryViewModel else {
            return SectionResult(skipReason: "提醒事项权限未开启，待办已跳过")
        }
        let todos = diaryViewModel.entries.filter { $0.category == .todo && range.contains($0.date) }
        guard !todos.isEmpty else {
            return SectionResult(skipReason: "提醒事项权限未开启，待办已跳过；本周期暂无日记待办")
        }
        let linked = todos.filter { $0.linkedReminderID != nil }.count
        let lines = [
            "本周期日记待办 \(todos.count) 条（其中 \(linked) 条已联动提醒）",
            "提醒事项未授权，系统待办已跳过"
        ]
        return SectionResult(content: lines, hasData: true)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - 记忆

    /// 记忆档案：按 lastUpdated 落在区间内的条目数（新增 = 条目的最近更新时间）。
    private func memorySection(in range: Range<Date>) -> SectionResult {
        guard let memoryProfileStore else {
            return SectionResult(skipReason: "记忆档案未接入，本周期记忆已跳过")
        }
        let added = memoryProfileStore.recentEntries.filter { range.contains($0.lastUpdated) }
        guard !added.isEmpty else {
            return SectionResult(content: ["本周期暂无新增档案"])
        }
        let line = "本周期新增档案 \(added.count) 条（偏好/项目/事实/灵感）"
        return SectionResult(content: [line], hasData: true)
    }

    // MARK: - 总结

    /// 一句话中性总结：按「有真实数据的分区数」分层，不编造具体数字。
    private static func summary(for period: ReportPeriod, dataSectionCount: Int) -> String {
        switch dataSectionCount {
        case 0:
            return "本周期暂无活动记录，去记点日记、打打卡，让报告更完整吧"
        case 1...2:
            return "本周期记录不多，先从一件小事开始坚持吧"
        default:
            return period == .week ? "本周很充实，继续保持" : "本月很充实，继续保持"
        }
    }

    // MARK: - 通用

    /// 摘要截断：超长文本保留前 maxLength 字。
    private static func summarize(_ text: String, maxLength: Int = 40) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }

    /// 单个数据源的分区结果：content 为空 + skipReason 为空 = 无数据。
    private struct SectionResult {
        var content: [String] = []
        var skipReason: String?
        /// 是否有真实数据（summary 分层用，零值语句不算）。
        var hasData = false
    }
}
