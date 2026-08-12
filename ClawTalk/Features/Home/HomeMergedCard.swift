import SwiftUI

/// 合并卡子功能条目：跳转到现有功能页（复用现有 Views，不复制大段代码）。
struct HomeSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
    let subtitle: String
    let destination: AnyView
}

/// 合并卡（主页网格）：图标 + 标题 + 摘要 + 可选实时徽标，点击进入合并页。
struct HomeMergedCard: View {
    let kind: HomeCardKind
    let settings: SettingsStore
    let careStore: CareReminderStore
    let habitStore: HabitStore
    let geofenceStore: GeofenceStore
    let gatewayConnection: GatewayConnection?
    var badge: String?

    var body: some View {
        NavigationLink {
            HomeMergedCardPage(
                kind: kind,
                settings: settings,
                careStore: careStore,
                habitStore: habitStore,
                geofenceStore: geofenceStore,
                gatewayConnection: gatewayConnection
            )
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(kind.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(kind.tint.opacity(0.9), in: Capsule())
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(kind.summary)
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
    }
}

/// 合并卡详情页：顶部全局语音输入大按钮 + 子功能分区列表。
struct HomeMergedCardPage: View {
    let kind: HomeCardKind

    @State private var careStore: CareReminderStore
    @State private var habitStore: HabitStore
    @State private var geofenceStore: GeofenceStore

    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?

    init(
        kind: HomeCardKind,
        settings: SettingsStore,
        careStore: CareReminderStore,
        habitStore: HabitStore,
        geofenceStore: GeofenceStore,
        gatewayConnection: GatewayConnection?
    ) {
        self.kind = kind
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        _careStore = State(initialValue: careStore)
        _habitStore = State(initialValue: habitStore)
        _geofenceStore = State(initialValue: geofenceStore)
    }

    var body: some View {
        List {
            Section {
                GlobalVoiceInput(settingsStore: settings)
                    .listRowBackground(Color.clear)
            }

            Section("功能分区") {
                ForEach(sections) { section in
                    NavigationLink {
                        section.destination
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .foregroundStyle(.primary)
                                Text(section.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: section.icon)
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(section.tint)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 各卡的分区子功能（复用现有功能页，全部为真实页面）。
    private var sections: [HomeSection] {
        switch kind {
        case .record:
            return [
                HomeSection(
                    id: "diary", title: "语音日记", icon: "waveform", tint: .pink,
                    subtitle: "说一段话，记下今天",
                    destination: AnyView(VoiceDiaryView(settingsStore: settings))
                ),
                HomeSection(
                    id: "capture", title: "随手捕捉", icon: "tray.and.arrow.down.fill", tint: .teal,
                    subtitle: "说一句，自动归档",
                    destination: AnyView(CaptureView(settingsStore: settings, careReminderStore: careStore))
                ),
                HomeSection(
                    id: "dictation", title: "文档口述", icon: "doc.plaintext.fill", tint: .blue,
                    subtitle: "口述转文档",
                    destination: AnyView(DictationListView(settingsStore: settings))
                ),
                HomeSection(
                    id: "writing", title: "语音写文章", icon: "pencil.and.outline", tint: .indigo,
                    subtitle: "说话成文",
                    destination: AnyView(WritingListView(settingsStore: settings))
                ),
                HomeSection(
                    id: "meeting", title: "会议纪要", icon: "person.2.fill", tint: .orange,
                    subtitle: "会议记录与待办",
                    destination: AnyView(MeetingListView(settingsStore: settings))
                )
            ]
        case .reminders:
            return [
                HomeSection(
                    id: "reminders", title: "提醒列表", icon: "bell.badge.fill", tint: .orange,
                    subtitle: "待办与定时提醒",
                    destination: AnyView(ReminderListView(store: careStore))
                ),
                HomeSection(
                    id: "anniversary", title: "纪念日", icon: "gift.fill", tint: .pink,
                    subtitle: "重要日子不错过",
                    destination: AnyView(AnniversariesView())
                ),
                HomeSection(
                    id: "geofence", title: "到家 / 离开", icon: "location.fill", tint: .blue,
                    subtitle: "进出区域提醒",
                    destination: AnyView(GeofenceListView(store: geofenceStore))
                )
            ]
        case .health:
            return [
                HomeSection(
                    id: "health", title: "健康概览", icon: "heart.fill", tint: .green,
                    subtitle: "步数与近 7 天趋势",
                    destination: AnyView(HealthDetailView(viewModel: HealthViewModel()))
                ),
                HomeSection(
                    id: "habit", title: "习惯打卡", icon: "checkmark.circle.fill", tint: .orange,
                    subtitle: "每日习惯追踪",
                    destination: AnyView(HabitsView(store: habitStore))
                ),
                HomeSection(
                    id: "health-report", title: "健康周报", icon: "heart.text.square.fill", tint: .red,
                    subtitle: "每周健康总结",
                    destination: AnyView(HealthReportView(healthViewModel: HealthViewModel(), careReminderStore: careStore))
                )
            ]
        case .report:
            return [
                HomeSection(
                    id: "briefing", title: "每日播报", icon: "sun.max.fill", tint: .orange,
                    subtitle: "天气 · 日程 · 待办",
                    destination: AnyView(DailyBriefingView(settings: settings, careStore: careStore))
                ),
                HomeSection(
                    id: "period", title: "周报月报", icon: "chart.bar.fill", tint: .indigo,
                    subtitle: "周期回顾报告",
                    destination: AnyView(ReportView(settings: settings))
                ),
                HomeSection(
                    id: "suggestion", title: "主动建议", icon: "lightbulb.fill", tint: .yellow,
                    subtitle: "智能体主动提醒",
                    destination: AnyView(SuggestionsView())
                )
            ]
        case .expense:
            return [
                HomeSection(
                    id: "expense", title: "语音记账", icon: "yensign.circle.fill", tint: .green,
                    subtitle: "按住说话记一笔",
                    destination: AnyView(ExpenseListView(settingsStore: settings))
                )
            ]
        case .travel:
            return [
                HomeSection(
                    id: "travel", title: "差旅管家", icon: "airplane", tint: .blue,
                    subtitle: "行程与出行提醒",
                    destination: AnyView(TravelListView(settings: settings))
                ),
                HomeSection(
                    id: "parking", title: "停车位置", icon: "parkingsign.circle.fill", tint: .purple,
                    subtitle: "停车记录与查找",
                    destination: AnyView(ParkingView())
                )
            ]
        case .knowledge:
            return [
                HomeSection(
                    id: "kb", title: "知识库问答", icon: "books.vertical.fill", tint: .purple,
                    subtitle: "问你的私人知识库",
                    destination: AnyView(KBView(settings: settings, gatewayConnection: gatewayConnection))
                ),
                HomeSection(
                    id: "summary", title: "长文摘要", icon: "text.badge.checkmark", tint: .blue,
                    subtitle: "长文一键总结",
                    destination: AnyView(SummarizeView(settingsStore: settings))
                )
            ]
        }
    }
}
