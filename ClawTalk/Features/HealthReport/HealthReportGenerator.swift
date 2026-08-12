import Foundation

/// 健康周报生成器：聚合近 7 天步数 + 提醒排程 + 语音日记，生成 HealthReport。
///
/// 数据源：
/// - 步数：优先复用 HealthViewModel（逐日粒度 + 授权状态分支，与健康卡一致）；
///   HealthViewModel 内部走 HealthCapability.steps(days: 7)（先授权后读总量，
///   再按自然日 HKStatisticsQuery 补齐逐日）。未注入时内部新建实例。
/// - 提醒：CareReminderStore —— 没有历史触发记录接口，按 repeatType 统计
///   本周窗口内「按排程预计触发」次数。
/// - 日记：VoiceDiaryViewModel.entries —— 统计本周窗口内条数。
///
/// 诚实原则：任一数据源未授权 / 失败 / 未注入 → 字段置 nil 或空数组，
/// 并写 skippedNotes 说明；generate() 永不 throw，UI 无需额外兜底。
@MainActor
struct HealthReportGenerator {

    /// 默认日目标步数（后续可在设置页调整）
    static let defaultTargetSteps = 6000

    private let healthViewModel: HealthViewModel?
    private let careReminderStore: CareReminderStore?
    private let diaryViewModel: VoiceDiaryViewModel?
    private let now: Date

    init(
        healthViewModel: HealthViewModel? = nil,
        careReminderStore: CareReminderStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        now: Date = Date()
    ) {
        self.healthViewModel = healthViewModel
        self.careReminderStore = careReminderStore
        self.diaryViewModel = diaryViewModel
        self.now = now
    }

    // MARK: - 生成

    /// 生成当前周周报。`forceRefresh` 为 true 时强制重读健康数据（下拉刷新用）。
    func generate(forceRefresh: Bool = false) async -> HealthReport {
        let stepsSnapshot = await loadSteps(forceRefresh: forceRefresh)

        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let fallbackWeekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let weekStart = stepsSnapshot.dates.first ?? fallbackWeekStart
        guard let weekEndExclusive = calendar.date(byAdding: .day, value: 1, to: todayStart) else {
            // 极端兜底（正常不会发生）：直接按今日窗口生成空周报
            return HealthReport(
                weekStart: weekStart,
                weekEnd: todayStart,
                steps: [],
                avgSteps: nil,
                totalSteps: nil,
                targetSteps: Self.defaultTargetSteps,
                goalDays: 0,
                diaryCount: nil,
                reminderTriggerCount: nil,
                skippedNotes: ["周窗口计算失败，请稍后重试"],
                insights: [],
                reportDate: todayStart,
                generatedAt: Date()
            )
        }
        let weekRange = weekStart..<weekEndExclusive

        var notes: [String] = []
        if let note = stepsSnapshot.skipNote { notes.append(note) }

        let reminder = reminderStats(in: weekRange)
        if let note = reminder.note { notes.append(note) }

        let diary = diaryStats(in: weekRange)
        if let note = diary.note { notes.append(note) }

        let target = Self.defaultTargetSteps
        let steps = stepsSnapshot.steps
        let total: Int?
        if !steps.isEmpty {
            total = steps.reduce(0, +)
        } else {
            total = stepsSnapshot.fallbackTotal
        }
        let avg = steps.isEmpty ? nil : (total ?? 0) / steps.count
        let goalDays = steps.filter { $0 >= target }.count

        let insights = Self.buildInsights(
            steps: steps,
            dates: stepsSnapshot.dates,
            avgSteps: avg,
            goalDays: goalDays,
            targetSteps: target,
            diaryCount: diary.count,
            diaryInjected: diaryViewModel != nil,
            reminderTriggerCount: reminder.count,
            reminderInjected: careReminderStore != nil
        )

        return HealthReport(
            weekStart: weekStart,
            weekEnd: todayStart,
            steps: steps,
            avgSteps: avg,
            totalSteps: total,
            targetSteps: target,
            goalDays: goalDays,
            diaryCount: diary.count,
            reminderTriggerCount: reminder.count,
            skippedNotes: notes,
            insights: insights,
            reportDate: todayStart,
            generatedAt: Date()
        )
    }

    // MARK: - 步数

    private func loadSteps(forceRefresh: Bool) async -> (
        steps: [Int],
        dates: [Date],
        fallbackTotal: Int?,
        skipNote: String?
    ) {
        let viewModel = healthViewModel ?? HealthViewModel()
        if forceRefresh {
            await viewModel.load()
        } else {
            await viewModel.loadIfNeeded()
        }

        switch viewModel.accessState {
        case .authorized:
            if !viewModel.dailySteps.isEmpty {
                return (
                    viewModel.dailySteps.map(\.steps),
                    viewModel.dailySteps.map(\.date),
                    nil,
                    nil
                )
            }
            if let weeklyTotal = viewModel.weeklyTotal {
                return ([], [], weeklyTotal, "步数逐日明细不可用，仅显示周总量")
            }
            return ([], [], nil, "健康数据为空，暂无步数")
        case .denied:
            return ([], [], nil, "健康数据权限未开启，步数已跳过（请在设置-健康中开启步数读取权限）")
        case .unavailable:
            return ([], [], nil, "此设备不支持健康数据，步数已跳过")
        case .failed:
            return ([], [], nil, "健康数据读取失败，步数已跳过")
        case .unknown:
            return ([], [], nil, "健康数据尚未加载")
        }
    }

    // MARK: - 提醒（按排程预计）

    private func reminderStats(in range: Range<Date>) -> (count: Int?, note: String?) {
        guard let careReminderStore else {
            return (nil, "提醒未接入，本周提醒已跳过")
        }
        let enabled = careReminderStore.reminders.filter { $0.enabled }
        guard !enabled.isEmpty else {
            // 有数据源但没有提醒：如实为 0，不算失败
            return (0, nil)
        }
        let calendar = Calendar.current
        var count = 0
        for reminder in enabled {
            switch reminder.repeatType {
            case .daily:
                count += Self.dayCount(in: range, calendar: calendar) { _ in true }
            case .workday:
                count += Self.dayCount(in: range, calendar: calendar) { Self.isWorkday($0) }
            case .none:
                if let scheduledDate = reminder.scheduledDate {
                    if range.contains(scheduledDate) { count += 1 }
                } else if let fireDate = careReminderStore.nextFireDate(for: reminder),
                          range.contains(fireDate) {
                    count += 1
                }
            }
        }
        return (count, nil)
    }

    /// 窗口内按 include 条件统计天数（逐日迭代，防溢出）。
    private static func dayCount(
        in range: Range<Date>,
        calendar: Calendar,
        include: (Date) -> Bool
    ) -> Int {
        var count = 0
        var day = calendar.startOfDay(for: range.lowerBound)
        while day < range.upperBound {
            if include(day) { count += 1 }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return count
    }

    private static func isWorkday(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        return (2...6).contains(weekday)
    }

    // MARK: - 日记

    private func diaryStats(in range: Range<Date>) -> (count: Int?, note: String?) {
        guard let diaryViewModel else {
            return (nil, "日记未接入，本周日记已跳过")
        }
        let count = diaryViewModel.entries.filter { range.contains($0.date) }.count
        return (count, nil)
    }

    // MARK: - Insights

    private static func buildInsights(
        steps: [Int],
        dates: [Date],
        avgSteps: Int?,
        goalDays: Int,
        targetSteps: Int,
        diaryCount: Int?,
        diaryInjected: Bool,
        reminderTriggerCount: Int?,
        reminderInjected: Bool
    ) -> [String] {
        var items: [String] = []

        if !steps.isEmpty {
            if let avgSteps {
                items.append("本周日均 \(avgSteps) 步")
            }
            let dayCount = max(steps.count, 1)
            let rate = Int((Double(goalDays) / Double(dayCount) * 100).rounded())
            items.append("\(goalDays)/\(dayCount) 天达到 \(targetSteps) 步目标（达标率 \(rate)%）")

            let maxValue = steps.max() ?? 0
            let minValue = steps.min() ?? 0
            // 全 0 或每天相同：不再报「最高/最低」，避免无意义文案
            let hasMeaningfulSteps = steps.contains { $0 > 0 }
            if hasMeaningfulSteps,
               let maxIndex = steps.firstIndex(of: maxValue),
               maxIndex < dates.count {
                items.append("步数最高：\(Self.weekdayLabel(dates[maxIndex]))（\(maxValue) 步）")
            }
            if hasMeaningfulSteps, maxValue != minValue,
               let minIndex = steps.firstIndex(of: minValue),
               minIndex < dates.count {
                items.append("步数最低：\(Self.weekdayLabel(dates[minIndex]))（\(minValue) 步）")
            }
        }

        if diaryInjected, let diaryCount {
            items.append(diaryCount > 0 ? "本周记了 \(diaryCount) 篇语音日记" : "本周还没有语音日记")
        }

        if reminderInjected, let reminderTriggerCount {
            items.append(
                reminderTriggerCount > 0
                    ? "本周按排程预计触发 \(reminderTriggerCount) 次提醒"
                    : "本周没有安排提醒"
            )
        }

        return items
    }

    private static func weekdayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
