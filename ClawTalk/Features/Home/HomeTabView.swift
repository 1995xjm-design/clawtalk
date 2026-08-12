import SwiftUI

/// 主页 Tab：顶部语音助手大卡位 + 「今日概览」横向统计卡 + 下方可配置合并卡片网格。
///
/// D2：23→8 卡合并（家庭共享移除，工具卡回工具页）；D3：长按卡片可移除（AppStorage 持久化，工具页可回加）；
/// B5：默认无壁纸 = 系统纯色跟随深浅，选壁纸后固定（深浅只改蒙层+卡片），NavigationStack 不再盖住壁纸层。
struct HomeTabView: View {
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?
    private let chatViewModel: ChatViewModel?

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]

    @State private var assistantViewModel: VoiceAssistantViewModel?

    // MARK: - 今日概览数据源（诚实空状态，不塞假数据）

    /// 今日提醒数：CareReminderStore 已就绪，实时读取（与提醒卡/简报卡同一数据源）。
    @State private var careStore: CareReminderStore

    /// 自动化数据源：本地任务实时读取；网关 cron 排程后回填 nextRunAt。
    @State private var automationViewModel: AutomationViewModel?

    // 合并卡共享 Store（MainActor 上下文中创建）
    @State private var habitStore: HabitStore
    @State private var geofenceStore: GeofenceStore
    /// 记账卡摘要数据源（本月收支）
    @State private var expenseStore: ExpenseStore

    /// D3：主页卡片自定义（长按移除 / 工具页添加），AppStorage 持久化。
    @AppStorage(HomeCardRegistry.storageKey) private var enabledCardKindsStorage = HomeCardRegistry.defaultStorageValue

    /// 今日日记数：TODO(主智能体接线) Diary 组暂无 DiaryStore 类，日记数据在
    /// VoiceDiaryViewModel.entries；等日记组接口就绪后改为「entries 中 date 为今天的条数」。
    @State private var todayDiaryCount = 0

    /// 待办数：TODO(主智能体接线) 待办数数据源待定（可参考 DailyBriefView 用
    /// RemindersCapability 读系统待办，或接日记组待办联动），就绪后替换。
    @State private var todayTodoCount = 0

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil, chatViewModel: ChatViewModel? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        self.chatViewModel = chatViewModel
        _careStore = State(initialValue: CareReminderStore())
        _habitStore = State(initialValue: HabitStore())
        _geofenceStore = State(initialValue: GeofenceStore())
        _expenseStore = State(initialValue: ExpenseStore())
    }

    /// 可配置卡片网格（D3：长按移除；全部移除后提供一键恢复）。
    private var cardGrid: some View {
        let kinds = HomeCardRegistry.enabledKinds(from: enabledCardKindsStorage)
        return Group {
            if kinds.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("主页卡片已全部移除")
                        .font(.subheadline.weight(.medium))
                    Text("长按卡片移除后回到工具页；这里可一键恢复全部")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("恢复全部卡片") {
                        enabledCardKindsStorage = HomeCardRegistry.defaultStorageValue
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.openClawRed)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(kinds) { kind in
                        HomeMergedCard(
                            kind: kind,
                            settings: settings,
                            careStore: careStore,
                            habitStore: habitStore,
                            geofenceStore: geofenceStore,
                            gatewayConnection: gatewayConnection,
                            badge: badgeText(for: kind)
                        )
                        .contextMenu {
                            Button(role: .destructive) {
                                enabledCardKindsStorage = HomeCardRegistry.removing(kind, from: enabledCardKindsStorage)
                            } label: {
                                Label("从主页移除", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .task { expenseStore.reload() }
            }
        }
    }

    var body: some View {
        ZStack {
            wallpaperLayer
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let assistantViewModel {
                            VoiceAssistantCardSlot(content: VoiceAssistantCardView(viewModel: assistantViewModel, settingsStore: settings))
                                .padding(.horizontal, 16)
                        } else {
                            VoiceAssistantCardSlot()
                                .padding(.horizontal, 16)
                        }

                        todayOverviewSection

                        VStack(alignment: .leading, spacing: 12) {
                            Text("常用卡片")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("长按卡片可移除；到工具页可重新添加")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            cardGrid
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 16)
                }
                .scrollContentBackground(.hidden)
                .background(.clear)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationTitle("主页")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    configureAssistantIfNeeded()
                    configureOverviewIfNeeded()
                }
            }
        }
    }

    /// 主页主题壁纸层（B5）：默认无壁纸 = 系统纯色（深浅色自适应）；
    /// 选了内置壁纸/自定义照片后壁纸固定，深浅切换只改蒙层与卡片。
    private var wallpaperLayer: some View {
        GeometryReader { geo in
            ZStack {
                if HomeWallpaper.hasSelectedWallpaper(settings.settings),
                   let image = HomeWallpaper.currentImage(settings: settings.settings) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: CGFloat((1 - settings.settings.homeBlurStrength) * 22))
                        .clipped()
                    Color.black.opacity(0.12)
                } else {
                    Color(.systemGroupedBackground)
                }
            }
            .ignoresSafeArea()
        }
    }

    /// 「今日概览」区：语音助手下方、常用卡片上方，4 个横向小统计卡。
    private var todayOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("今日概览")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(spacing: 12) {
                OverviewStatCard(
                    title: "今日提醒",
                    value: "\(careStore.todayReminderCount)",
                    icon: "bell.badge.fill",
                    tint: .orange
                )
                OverviewStatCard(
                    title: "今日日记",
                    value: "\(todayDiaryCount)",
                    icon: "book.fill",
                    tint: .pink
                )
                OverviewStatCard(
                    title: "待办",
                    value: "\(todayTodoCount)",
                    icon: "checklist",
                    tint: .green
                )
                OverviewStatCard(
                    title: "下次执行",
                    value: automationNextRunText,
                    icon: "bolt.fill",
                    tint: .blue
                )
            }
        }
        .padding(.horizontal, 16)
    }

    /// 卡片实时徽标（与各 Store 共用同一数据源；无数据时返回 nil 显示纯卡片）。
    private func badgeText(for kind: HomeCardKind) -> String? {
        switch kind {
        case .reminders:
            let count = careStore.todayReminderCount
            return count > 0 ? "今日 \(count)" : nil
        case .expense:
            let summary = expenseStore.monthSummary()
            if summary.expense > 0 { return "¥\(summary.expense.expenseAmountText)" }
            if summary.income > 0 { return "¥\(summary.income.expenseAmountText)" }
            return nil
        default:
            return nil
        }
    }

    /// 自动化下次执行文案：取已启用任务中最近的 nextRunAt（网关排程后回填）；
    /// 无任务 / 未排程时诚实空状态，不造假时间。
    private var automationNextRunText: String {
        guard let automationViewModel else { return "—" }
        let next = automationViewModel.tasks
            .filter { $0.enabled }
            .compactMap { $0.nextRunAt }
            .min()
        if let next {
            return Self.timeText(next)
        }
        return automationViewModel.tasks.isEmpty ? "暂无" : "待排程"
    }

    /// 语音助手接线：不依赖聊天页 ChatViewModel，直接创建会话管理器并注入 STT/TTS 服务；
    /// 若当前有打开的聊天页（chatViewModel 非 nil），则复用其发送链路作为兼容路径。
    private func configureAssistantIfNeeded() {
        guard assistantViewModel == nil else { return }
        let vm = VoiceAssistantViewModel(
            settings: settings,
            gatewayConnection: gatewayConnection,
            chatViewModel: chatViewModel
        )
        let s = settings.settings
        vm.configure(
            transcription: AppleSTTService(language: s.whisperLanguage),
            speech: AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
        )
        assistantViewModel = vm
    }

    /// 今日概览接线：创建自动化数据源（本地任务实时读取；网关 cron 排程后回填 nextRunAt）。
    private func configureOverviewIfNeeded() {
        guard automationViewModel == nil else { return }
        automationViewModel = AutomationViewModel(settings: settings)
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// 今日概览小统计卡：图标 + 数值 + 标签，横向四连排布。
private struct OverviewStatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
