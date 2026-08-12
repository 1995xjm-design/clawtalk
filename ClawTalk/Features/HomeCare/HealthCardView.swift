import SwiftUI

/// 副主页「健康」卡片：今日步数 + 近 7 天迷你趋势条 + 图标，点击进入健康详情页。
/// 自带 NavigationLink（与 ReminderCardView 同款接线），直接放进 LazyVGrid 一格。
struct HealthCardView: View {
    @State private var viewModel = HealthViewModel()

    var body: some View {
        NavigationLink {
            HealthDetailView(viewModel: viewModel)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 5) {
                    Text("健康")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HealthCardSummary(viewModel: viewModel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .task { await viewModel.loadIfNeeded() }
    }
}

/// 健康卡摘要：按授权状态显示今日步数 / 迷你趋势 / 诚实空状态引导。
struct HealthCardSummary: View {
    let viewModel: HealthViewModel

    var body: some View {
        Group {
            switch viewModel.accessState {
            case .unknown:
                Text(viewModel.isLoading ? "正在读取步数…" : "点击查看步数与健康数据")
            case .authorized:
                VStack(alignment: .leading, spacing: 5) {
                    Text(todayText)
                    if !viewModel.dailySteps.isEmpty {
                        StepMiniBars(days: viewModel.dailySteps)
                    }
                }
            case .denied:
                Text("未开启健康权限，点击去设置开启")
            case .unavailable:
                Text(viewModel.errorMessage ?? "此设备不支持健康数据")
            case .failed:
                Text(viewModel.errorMessage ?? "读取失败，点击重试")
            }
        }
    }

    private var todayText: String {
        guard let steps = viewModel.todaySteps else { return "今日暂无步数记录" }
        return "今日 \(steps) 步"
    }
}

/// 近 7 天迷你趋势条（卡片用）：7 根小柱，无文字，今天高亮。
struct StepMiniBars: View {
    let days: [HealthViewModel.DaySteps]

    private var maxSteps: Int {
        max(days.map(\.steps).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(days) { day in
                Capsule()
                    .fill(barColor(for: day))
                    .frame(height: barHeight(for: day))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22)
    }

    private func barHeight(for day: HealthViewModel.DaySteps) -> CGFloat {
        guard day.steps > 0 else { return 3 }
        return max(3, CGFloat(day.steps) / CGFloat(maxSteps) * 22)
    }

    private func barColor(for day: HealthViewModel.DaySteps) -> Color {
        Calendar.current.isDate(day.date, inSameDayAs: Date()) ? .green : .green.opacity(0.45)
    }
}
