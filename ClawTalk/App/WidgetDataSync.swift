import Foundation
import WidgetKit

/// 小组件数据写入（主 App 侧唯一入口）：键契约与 ClawTalkWidget/ClawTalkTimelineProvider.swift 保持一致。
/// 记账/提醒等数据变化时调用 write(...)，内部刷新小组件时间线（WidgetCenter.reloadAllTimelines）。
enum WidgetDataSync {
    static let suiteName = "group.7518554"

    static let channelNameKey = "widget_channel_name"
    static let gatewayStatusKey = "widget_gateway_status"
    static let recentSessionKey = "widget_recent_session"
    static let nextReminderKey = "widget_next_reminder"
    static let stepsKey = "widget_steps"
    static let healthKey = "widget_health"
    static let expenseKey = "widget_expense"
    static let expenseTodayKey = "widget_expense_today"
    static let expenseMonthKey = "widget_expense_month"
    static let travelKey = "widget_travel"
    static let updatedAtKey = "widget_updated_at"

    /// 记账/提醒数据变化通知：主 App 收到后立即刷新小组件（3 秒同步循环兜底）。
    static let dataDidChangeNotification = Notification.Name("ClawTalkWidgetDataDidChange")

    /// 写入一组键值并刷新小组件时间线。
    static func write(_ values: [String: Any]) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: updatedAtKey)
        defaults.synchronize()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - 记账摘要（真实数据，不造假）

    /// 今日/本月收支摘要（读记账 UserDefaults；全空时返回空串，小组件显示诚实空态）。
    static func expenseSummaries() -> (today: String, month: String, legacy: String) {
        let entries = decodedExpenseEntries()
        let calendar = Calendar.current
        let now = Date()
        let monthInterval = calendar.dateInterval(of: .month, for: now)
        let todayInterval = calendar.dateInterval(of: .day, for: now)

        var monthIncome = 0.0
        var monthExpense = 0.0
        var todayIncome = 0.0
        var todayExpense = 0.0
        for entry in entries {
            if let monthInterval, monthInterval.contains(entry.date) {
                switch entry.type {
                case .income: monthIncome += entry.amount
                case .expense: monthExpense += entry.amount
                }
            }
            if let todayInterval, todayInterval.contains(entry.date) {
                switch entry.type {
                case .income: todayIncome += entry.amount
                case .expense: todayExpense += entry.amount
                }
            }
        }
        return (
            expenseLine(expense: todayExpense, income: todayIncome),
            expenseLine(expense: monthExpense, income: monthIncome),
            legacyExpenseLine(expense: monthExpense, income: monthIncome)
        )
    }

    private static func expenseLine(expense: Double, income: Double) -> String {
        if expense <= 0 && income <= 0 { return "" }
        if income <= 0 { return "支出 ¥\(expense.expenseAmountText)" }
        if expense <= 0 { return "收入 ¥\(income.expenseAmountText)" }
        return "支出 ¥\(expense.expenseAmountText) · 收入 ¥\(income.expenseAmountText)"
    }

    private static func legacyExpenseLine(expense: Double, income: Double) -> String {
        if expense <= 0 && income <= 0 { return "" }
        if income <= 0 { return "本月支出 ¥\(expense.expenseAmountText)" }
        if expense <= 0 { return "本月收入 ¥\(income.expenseAmountText)" }
        return "本月支出 ¥\(expense.expenseAmountText) · 收入 ¥\(income.expenseAmountText)"
    }

    private static func decodedExpenseEntries() -> [ExpenseEntry] {
        guard let data = UserDefaults.standard.data(forKey: "expense_entries_v1"),
              let entries = try? JSONDecoder().decode([ExpenseEntry].self, from: data) else { return [] }
        return entries
    }

    // MARK: - 出行/停车摘要

    /// 最近一条停车摘要（如「停车：商场 B2」；无记录返回空串）。
    static func travelText() -> String {
        guard let data = UserDefaults.standard.data(forKey: "clawtalk_parking_records_v1"),
              let records = try? JSONDecoder().decode([ParkingRecord].self, from: data),
              let first = records.first else { return "" }
        let place = first.address ?? first.note ?? "已记录位置"
        return "停车：\(place)"
    }

    // MARK: - 健康/步数摘要

    /// 健康页加载成功后写入步数/健康摘要（授权成功才写，未授权保持空态）。
    static func writeHealth(stepsToday: Int?, weeklyTotal: Int?) {
        var values: [String: Any] = [:]
        if let stepsToday {
            values[stepsKey] = "今日 \(stepsToday) 步"
        }
        var healthParts: [String] = []
        if let stepsToday { healthParts.append("今日 \(stepsToday) 步") }
        if let weeklyTotal { healthParts.append("近7天 \(weeklyTotal) 步") }
        if !healthParts.isEmpty {
            values[healthKey] = healthParts.joined(separator: " · ")
        }
        guard !values.isEmpty else { return }
        write(values)
    }
}
