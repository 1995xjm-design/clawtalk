import SwiftUI

/// 主页「健康周报」卡：本周总步数 + 达标率摘要，点击进入健康周报页。
/// 样式对齐 DailyBriefingCardView（图标 + 标题 + 摘要）。
///
/// 自动生成：.task 时生成当前周（含生成时间）；健康权限未开 / 无数据时
/// 诚实显示引导文案，不展示估算数字。
///
/// 主智能体接线：在 HomeTabView 快捷入口卡片网格（LazyVGrid）里加一行：
///     HealthReportCardView(settings: settings)
/// 若希望与「健康」卡共享一次健康授权/加载，可将 HealthCardView 与本卡
/// 注入同一个 HealthViewModel 实例（接线时由主智能体统一处理）。
struct HealthReportCardView: View {
    @State private var report: HealthReport?
    @State private var healthViewModel: HealthViewModel
    @State private var careStore: CareReminderStore
    @State private var diaryViewModel: VoiceDiaryViewModel

    init(
        settings: SettingsStore? = nil,
        healthViewModel: HealthViewModel? = nil,
        careReminderStore: CareReminderStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        _healthViewModel = State(initialValue: healthViewModel ?? HealthViewModel())
        _careStore = State(initialValue: careReminderStore ?? CareReminderStore())
        _diaryViewModel = State(initialValue: diaryViewModel ?? VoiceDiaryViewModel(settingsStore: resolvedSettings))
    }

    var body: some View {
        NavigationLink {
            HealthReportView(
                healthViewModel: healthViewModel,
                careReminderStore: careStore,
                diaryViewModel: diaryViewModel
            )
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("健康周报")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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
        .task { await generate() }
    }

    /// 摘要：有真实数据 → 总步数 + 达标率；无数据 → 诚实引导；未生成 → 生成中。
    private var summaryText: String {
        guard let report else { return "生成中…" }
        if report.hasStepsData {
            var parts: [String] = ["本周 \(report.totalSteps ?? 0) 步"]
            if let rate = report.goalRate {
                parts.append("达标率 \(Int((rate * 100).rounded()))%")
            }
            parts.append("生成于 \(report.generatedTimeText)")
            return parts.joined(separator: " · ")
        }
        return "暂无步数数据，开启健康权限后生成真实周报"
    }

    private func generate() async {
        let generator = HealthReportGenerator(
            healthViewModel: healthViewModel,
            careReminderStore: careStore,
            diaryViewModel: diaryViewModel
        )
        report = await generator.generate()
    }
}
