import SwiftUI
import UIKit

/// 健康详情页：今日步数 / 近 7 天每日列表 + 简单柱状图（纯 SwiftUI，无第三方库）。
/// 诚实空状态：未授权 → 引导去系统设置开启；无记录 → 明示暂无，不造假。
struct HealthDetailView: View {
    let viewModel: HealthViewModel

    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            switch viewModel.accessState {
            case .unknown:
                loadingRow
            case .authorized:
                todaySection
                weeklySection
                if allDaysZero {
                    noRecordHintSection
                }
            case .denied:
                deniedSection
            case .unavailable, .failed:
                errorSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("健康")
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.loadIfNeeded() }
        .refreshable { await viewModel.load() }
    }

    // MARK: - 状态分支

    private var loadingRow: some View {
        Section {
            HStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("正在读取健康数据…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    private var deniedSection: some View {
        Section {
            ContentUnavailableView {
                Label("健康数据未授权", systemImage: "heart.slash")
            } description: {
                Text("ClawTalk 需要读取「步数」才能展示健康卡。\n请在 设置 → 隐私与安全性 → 健康 中允许 ClawTalk 读取步数。")
            } actions: {
                Button("去设置开启") {
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var errorSection: some View {
        Section {
            ContentUnavailableView {
                Label("健康数据读取失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(viewModel.errorMessage ?? "请稍后重试")
            } actions: {
                Button("重新加载") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.borderedProminent)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var noRecordHintSection: some View {
        Section {
            Text("本周还没有步数记录，走起来后再来看看。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - 数据区块

    private var todaySection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "figure.walk")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.green)
                Text("今日步数")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.todaySteps ?? 0)")
                    .font(.title1.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("步")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("今日")
        }
    }

    private var weeklySection: some View {
        Section {
            StepBarChart(days: viewModel.dailySteps)
            ForEach(viewModel.dailySteps) { day in
                HStack {
                    Text(dayLabel(day.date))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(day.steps) 步")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("近 7 天")
        } footer: {
            if let total = viewModel.weeklyTotal {
                Text("近 7 天合计 \(total) 步")
            }
        }
    }

    // MARK: - 辅助

    private var allDaysZero: Bool {
        !viewModel.dailySteps.isEmpty && viewModel.dailySteps.allSatisfy { $0.steps == 0 }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d EEE"
        return formatter.string(from: date)
    }
}

/// 近 7 天简单柱状图（纯 SwiftUI）：每根柱 = 当天步数，今天高亮。
struct StepBarChart: View {
    let days: [HealthViewModel.DaySteps]

    private var maxSteps: Int {
        max(days.map(\.steps).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(days) { day in
                VStack(spacing: 4) {
                    Text("\(day.steps)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(barColor(for: day))
                        .frame(height: barHeight(for: day))
                        .frame(maxWidth: .infinity)
                    Text(barLabel(for: day.date))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .frame(height: 170)
        .padding(.vertical, 6)
    }

    private func barHeight(for day: HealthViewModel.DaySteps) -> CGFloat {
        guard day.steps > 0 else { return 4 }
        return max(4, CGFloat(day.steps) / CGFloat(maxSteps) * 110)
    }

    private func barColor(for day: HealthViewModel.DaySteps) -> Color {
        Calendar.current.isDate(day.date, inSameDayAs: Date()) ? .green : .green.opacity(0.45)
    }

    private func barLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return weekdays[calendar.component(.weekday, from: date) - 1]
    }
}
