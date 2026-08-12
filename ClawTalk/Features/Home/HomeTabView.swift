import SwiftUI

/// 主页 Tab：顶部语音助手大卡位 + 「今日概览」横向统计卡 + 下方快捷卡片网格。
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

    // 33 项功能包的 Store（卡片需要共享实例；MainActor 上下文中创建）
    @State private var fileVaultStore: FileVaultStore
    @State private var habitStore: HabitStore
    @State private var geofenceStore: GeofenceStore
    @State private var emergencyStore: EmergencyStore

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
        _fileVaultStore = State(initialValue: FileVaultStore())
        _habitStore = State(initialValue: HabitStore())
        _geofenceStore = State(initialValue: GeofenceStore())
        _emergencyStore = State(initialValue: EmergencyStore(settings: SettingsStore()))
    }

    /// 快捷入口卡片网格（拆出独立计算属性，避免 SwiftUI 类型检查超时）。
    private var cardGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {

                            // 提醒卡（自带 NavigationLink → 提醒列表）
                            ReminderCardView()

                            // 每日简报卡（今日提醒/日程/待办/天气一览，HomeCare 组已交付）
                            DailyBriefCardView()

                            // 健康卡（步数摘要 + 近 7 天趋势，自带 NavigationLink → 健康详情）
                            HealthCardView()

                            // 语音日记卡
                            HomeCardView(
                                card: HomeCard(
                                    id: "voice-diary",
                                    title: "语音日记",
                                    icon: "waveform",
                                    color: .pink,
                                    summary: "说一段话，记下今天",
                                    destination: VoiceDiaryView(settingsStore: settings)
                                )
                            )

                            // 我的记忆卡（第二大脑，自带 NavigationLink → 记忆中心）
                            MemoryHubCardView(settings: settings, gatewayConnection: gatewayConnection)

                            // 自动化卡
                            HomeCardView(
                                card: HomeCard(
                                    id: "automation",
                                    title: "自动化",
                                    icon: "bolt.fill",
                                    color: .blue,
                                    summary: "自动流程与快捷指令",
                                    destination: AutomationListView(settings: settings)
                                )
                            )

                            // 语音记账卡
                            ExpenseCardView(settings: settings)

                            // 随手捕捉卡
                            CaptureCardView(settings: settings)

                            // 会议纪要卡
                            MeetingCardView(settingsStore: settings)

                            // 每日播报卡
                            DailyBriefingCardView(settings: settings)

                            // 文档口述卡
                            DictationCardView(settingsStore: settings)

                            // 家庭共享提醒卡
                            FamilyShareCardView(settings: settings)

                            // 健康周报卡
                            HealthReportCardView(settings: settings)

                            // 习惯打卡卡
                            HabitCardView(store: habitStore)

                            // 到家/离开提醒卡
                            GeofenceCardView(store: geofenceStore)

                            // 停车位置卡
                            ParkingCardView()

                            // 差旅管家卡
                            TravelCardView()

                            // 紧急求助卡
                            EmergencyHomeCardView(store: emergencyStore)

                            // 重要文件防丢卡
                            FileVaultCardView(store: fileVaultStore)

                            // 知识库问答卡
                            KBCardView(settings: settings, gatewayConnection: gatewayConnection)

                            // 周报月报卡
                            ReportCardView(settings: settings)

                            // 主动建议卡
                            SuggestionHomeCard()

                            // 长文摘要卡
                            SummarizeCardView(settingsStore: settings)

                            // 纪念日提醒卡
                            AnniversaryCardView()

                            // 语音写文章卡
                            WritingCardView(settingsStore: settings)

                            // 睡前陪伴卡
                            WindDownCardView(settings: settings)
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
                            Text("快捷入口")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            cardGrid
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 16)
                }
                .scrollContentBackground(.hidden)
                .background(.clear)
                .navigationTitle("主页")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    configureAssistantIfNeeded()
                    configureOverviewIfNeeded()
                }
            }
        }
    }

    /// 主页主题壁纸层：内置壁纸/自定义照片 + 毛玻璃（模糊强度随设置）+ 轻度暗化。
    private var wallpaperLayer: some View {
        GeometryReader { geo in
            ZStack {
                if let image = HomeWallpaper.currentImage(settings: settings.settings) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .blur(radius: CGFloat((1 - settings.settings.homeBlurStrength) * 22))
                        .clipped()
                } else {
                    Color(.systemGroupedBackground)
                }
                Color.black.opacity(0.12)
            }
            .ignoresSafeArea()
        }
    }

    /// 「今日概览」区：语音助手下方、快捷入口上方，4 个横向小统计卡。
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