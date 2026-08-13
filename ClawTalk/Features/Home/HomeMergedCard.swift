import HamsteriOS
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

/// 合并卡（主页网格）：图标 + 标题 + 摘要 + 可选实时徽标。
/// S10：纯内容视图（导航由 HomeTabView 按编辑态包裹），尺寸区分小/中/大，毛玻璃材质贴近 iOS 桌面小组件。
struct HomeMergedCard: View {
    let kind: HomeCardKind
    let settings: SettingsStore
    let careStore: CareReminderStore
    let habitStore: HabitStore
    let geofenceStore: GeofenceStore
    let expenseStore: ExpenseStore
    let gatewayConnection: GatewayConnection?
    var size: HomeCardSize = .medium
    var badge: String?

    var body: some View {
        Group {
            switch size {
            case .small:
                smallLayout
            case .medium, .large:
                standardLayout
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }

    /// 小卡：图标 + 标题（对齐 iOS 小号小组件，信息密度低）。
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(kind.tint)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            Spacer(minLength: 0)

            Text(kind.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 中/大卡：图标 + 徽标 + 标题 + 摘要。
    private var standardLayout: some View {
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
    }

    private var minHeight: CGFloat {
        switch size {
        case .small: return 100
        case .medium: return 170 // 方块卡片：一行 2 个，高≈宽（明哥要求）
        case .large: return 150
        }
    }
}

/// 合并卡详情页（N3 重构）：4 方形功能分区网格 + 底部悬浮圆麦。
/// - 功能分区每格显示「名称 + 图标 + 最近记录摘要/数量」（有数据源的真实统计，无则诚实空态）；
/// - 悬浮麦：按住短语音（≤60 秒），按住上滑切长录音（≤60 分钟），悬浮不挡内容滚动。
struct HomeMergedCardPage: View {
    let kind: HomeCardKind

    @State private var careStore: CareReminderStore
    @State private var habitStore: HabitStore
    @State private var geofenceStore: GeofenceStore
    @State private var expenseStore: ExpenseStore
    /// 语音日记数据源（记录卡摘要；@MainActor，延迟在 .task 创建）
    @State private var diaryViewModel: VoiceDiaryViewModel?
    /// 健康数据源（异步加载；未授权/失败时为 nil，走诚实空态）
    @State private var healthViewModel: HealthViewModel?

    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?

    private let tileColumns = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]

    init(
        kind: HomeCardKind,
        settings: SettingsStore,
        careStore: CareReminderStore,
        habitStore: HabitStore,
        geofenceStore: GeofenceStore,
        expenseStore: ExpenseStore,
        gatewayConnection: GatewayConnection?
    ) {
        self.kind = kind
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        _careStore = State(initialValue: careStore)
        _habitStore = State(initialValue: habitStore)
        _geofenceStore = State(initialValue: geofenceStore)
        _expenseStore = State(initialValue: expenseStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("功能分区")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("点卡片进入功能页；下方悬浮麦按住说话、上滑切长录音")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: tileColumns, spacing: 12) {
                    ForEach(sections) { section in
                        NavigationLink {
                            section.destination
                        } label: {
                            functionTile(section)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .padding(.bottom, 220)
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            GlobalVoiceInputFloating(settingsStore: settings)
                .padding(.bottom, 20)
        }
        .task {
            if diaryViewModel == nil {
                diaryViewModel = VoiceDiaryViewModel(settingsStore: settings)
            }
            if healthViewModel == nil {
                let vm = HealthViewModel()
                await vm.loadIfNeeded()
                healthViewModel = vm
            }
        }
    }

    // MARK: - 4 方形功能格

    private func functionTile(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: section.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(section.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(tileSummary(for: section.id) ?? section.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    /// 功能格摘要：优先显示真实数据；无数据源/无记录时回落副标题（诚实空态）。
    private func tileSummary(for sectionID: String) -> String? {
        switch sectionID {
        case "diary":
            let count = diaryViewModel?.entries.count ?? 0
            return count > 0 ? "\(count) 条日记" : "暂无日记"
        case "reminders":
            let count = careStore.todayReminderCount
            return count > 0 ? "今日 \(count) 条" : "暂无今日提醒"
        case "geofence":
            let count = geofenceStore.regions.count
            return count > 0 ? "\(count) 个区域" : "暂无区域"
        case "habit":
            let done = habitStore.todayCompletedCount
            let due = habitStore.todayDueCount
            return due > 0 ? "今日 \(done)/\(due) 已完成" : "暂无习惯"
        case "health":
            if let steps = healthViewModel?.todaySteps {
                return "今日 \(steps) 步"
            }
            return nil
        case "expense":
            let summary = expenseStore.monthSummary()
            if summary.expense > 0 { return "本月支出 ¥\(summary.expense.expenseAmountText)" }
            if summary.income > 0 { return "本月收入 ¥\(summary.income.expenseAmountText)" }
            return "暂无账目"
        default:
            return nil
        }
    }

    /// 各卡的分区子功能（复用现有功能页，全部为真实页面）。
    private var sections: [HomeSection] {
        switch kind {
        case .memory:
            return [
                HomeSection(
                    id: "memory", title: "我的记忆", icon: "brain.head.profile", tint: .purple,
                    subtitle: "个人档案 · 对话沉淀 · 记忆搜索",
                    destination: AnyView(MemoryHubView(settings: settings, gatewayConnection: gatewayConnection))
                )
            ]
        case .cloneTalk:
            return [
                HomeSection(
                    id: "clone-talk", title: "AI 分身", icon: "person.crop.circle.badge.clock", tint: .pink,
                    subtitle: "以你的口吻生成回复草稿",
                    destination: AnyView(CloneTalkView(settingsStore: settings))
                )
            ]
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
        case .keyboard:
            return [
                HomeSection(
                    id: "now", title: "Now ClawTalk", icon: "brain.head.profile", tint: .purple,
                    subtitle: "输入采集 · 剪贴板 · AI 分析",
                    destination: AnyView(ClawTalkPanelHost())
                ),
                HomeSection(
                    id: "insight", title: "每日洞察", icon: "sparkles", tint: .orange,
                    subtitle: "心灵陪伴 · 事务指导",
                    destination: AnyView(AutoInsightPanelHost())
                ),
                HomeSection(
                    id: "freq", title: "智能调频", icon: "bolt.fill", tint: .teal,
                    subtitle: "词频优化 · 新词发现",
                    destination: AnyView(SmartFreqPanelHost())
                ),
                HomeSection(
                    id: "chat-target", title: "聊天档案", icon: "person.crop.circle.badge.heart", tint: .pink,
                    subtitle: "聊天对象背景档案",
                    destination: AnyView(HeartTargetPanelHost())
                )
            ]
        }
    }
}

// MARK: - 键盘智能卡真实页面（UIViewControllerRepresentable 包 HamsteriOS 页面，防崩兜底）

/// 防崩兜底页：控制器创建/加载异常时诚实提示，不把异常抛给 SwiftUI。
private final class KeyboardHostFailureViewController: UIViewController {
    private let reason: String

    init(reason: String) {
        self.reason = reason
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let label = UILabel()
        label.text = "键盘功能加载失败：\(reason)"
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .footnote)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}

/// 安全创建控制器：任何初始化异常都回退到诚实提示页，保证主程序不崩。
private enum KeyboardPanelHost {
    static func safe(make: @escaping () throws -> UIViewController) -> UIViewController {
        do {
            return try make()
        } catch {
            return KeyboardHostFailureViewController(reason: error.localizedDescription)
        }
    }
}

/// Now ClawTalk：输入采集 · 剪贴板 · AI 分析
struct ClawTalkPanelHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        KeyboardPanelHost.safe { ClawTalkViewController() }
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// 每日洞察：心灵陪伴 · 事务指导
struct AutoInsightPanelHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        KeyboardPanelHost.safe { AutoInsightViewController() }
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// 智能调频：词频优化 · 新词发现
struct SmartFreqPanelHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        KeyboardPanelHost.safe { SmartFreqViewController() }
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

/// 聊天档案：聊天对象背景档案
struct HeartTargetPanelHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        KeyboardPanelHost.safe { HeartTargetSettingsViewController() }
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}