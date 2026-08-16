import Combine
import SwiftUI

/// 主页 Tab：顶部语音助手大卡位 + 「今日概览」横向统计卡 + 下方可配置合并卡片网格。
///
/// S10：卡片系统升级为 iOS 桌面小组件质感——
/// - 壁纸修复：NavigationStack 容器背景透明，壁纸层透出（N9）；
/// - 卡片尺寸：小（1 列）/ 中（2 列）/ 大（4 列），AppStorage 持久化；
/// - 拖动排序：编辑态 draggable + dropDestination，顺序持久化；
/// - 编辑态：长按卡片进入（抖动 + 移除 × + 尺寸切换），点空白或「完成」退出；
/// - 毛玻璃：卡片背景 .ultraThinMaterial + 细描边 + 轻阴影（S11：跟随「全局毛玻璃」开关，关=纯色）；
/// - 「我的记忆」并入网格（默认中卡，今日概览下方第一格）。
struct HomeTabView: View {
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?
    private let chatViewModel: ChatViewModel?
    /// N0：主页空白处长按 → 工具页（由 App 层接线弹 ToolsView）。
    private let onOpenTools: (() -> Void)?
    /// H1：实时语音入口回调（由 App 层接线弹 RealtimeVoiceView 全屏页；nil = 不显示入口）。
    private let onOpenRealtimeVoice: (() -> Void)?
    /// S10：4 列弹性网格（小卡 1 列 / 中卡 2 列 / 大卡 4 列，对齐 iOS 小组件比例）。
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2) // 明哥要求：一行 2 个

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
    /// C9：记忆/分身卡数据源（档案数；与 MemoryHub / CloneTalk 同一存储）。
    @State private var memoryStore: MemoryProfileStore
    /// C9：出行卡数据源（下一行程；与 TravelListView 同一存储）。
    @State private var travelStore: TravelStore
    /// C9：知识卡数据源（问答数；与 KBView 同一存储）。
    @State private var kbStore: KBStore
    /// C9：文件防丢卡数据源（文件数；与 FileVaultView 共用 shared 实例）。
    @State private var fileVaultStore: FileVaultStore
    /// C9：健康卡数据源（今日步数；异步加载，未授权/失败走诚实空态）。
    @State private var healthViewModel: HealthViewModel?

    /// D3：主页卡片自定义（长按移除 / 工具页添加），AppStorage 持久化（顺序即排布）。
    @AppStorage(HomeCardRegistry.storageKey) private var enabledCardKindsStorage = HomeCardRegistry.defaultStorageValue
    /// S10：卡片尺寸持久化（`kind:size,...`）。
    @AppStorage(HomeCardRegistry.sizeStorageKey) private var cardSizesStorage = ""

    /// S10：卡片编辑态（长按卡片进入；点空白 / 「完成」退出）。
    @State private var isEditingCards = false
    /// T4：主页「常用卡片」标题行「管理」按钮弹出卡片管理页。
    @State private var isManagingCards = false
    /// S10：拖拽目标高亮卡片。
    @State private var targetedKind: HomeCardKind?
    /// S10：编辑态抖动驱动。
    @State private var wobbleTick = false
    /// C9：Store 变化刷新信号——@State 持有的 Store 不自动触发重绘，
    /// 订阅 objectWillChange 递增该值，让卡面实时数据/角标随数据变化刷新。
    @State private var storeRefreshTick = 0

    /// J3：语音日记数据源（今日日记数/待办数统计；与日记组共用 entries 持久化）。
    @State private var diaryViewModel: VoiceDiaryViewModel?

    /// J3：今日日记数——语音日记 entries 中今天创建的条数（含日记/待办/灵感类别）。
    private var todayDiaryCount: Int {
        guard let diaryViewModel else { return 0 }
        return diaryViewModel.entries.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    /// J3：今日待办数——语音日记中自动归类为待办且今天创建的条数（诚实来源：本地日记待办联动）。
    private var todayTodoCount: Int {
        guard let diaryViewModel else { return 0 }
        return diaryViewModel.entries.filter { $0.category == .todo && Calendar.current.isDateInToday($0.date) }.count
    }

    init(
        settings: SettingsStore,
        gatewayConnection: GatewayConnection? = nil,
        chatViewModel: ChatViewModel? = nil,
        onOpenTools: (() -> Void)? = nil,
        onOpenRealtimeVoice: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        self.chatViewModel = chatViewModel
        self.onOpenTools = onOpenTools
        self.onOpenRealtimeVoice = onOpenRealtimeVoice
        _careStore = State(initialValue: CareReminderStore())
        _habitStore = State(initialValue: HabitStore())
        _geofenceStore = State(initialValue: GeofenceStore())
        _expenseStore = State(initialValue: ExpenseStore())
        _memoryStore = State(initialValue: MemoryProfileStore(settings: settings))
        _travelStore = State(initialValue: TravelStore())
        _kbStore = State(initialValue: KBStore(settings: settings))
        _fileVaultStore = State(initialValue: FileVaultStore.shared)
    }

    var body: some View {
        ZStack {
            wallpaperLayer
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        assistantSection

                        todayOverviewSection

                        cardsSection
                    }
                    .padding(.vertical, 16)
                    .padding(.bottom, 240)
                }
                .scrollContentBackground(.hidden)
                .background(.clear)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.6)
                        .onEnded { _ in
                            if settings.settings.hapticsEnabled {
                                Haptics.impact(.medium)
                            }
                            onOpenTools?()
                        }
                )
                .onAppear {
                    migrateCardStorageIfNeeded()
                    configureAssistantIfNeeded()
                    configureOverviewIfNeeded()
                }
                .task {
                    await configureHealthIfNeeded()
                }
                .onChange(of: isEditingCards) { _, editing in
                    if editing {
                        withAnimation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true)) {
                            wobbleTick = true
                        }
                    } else {
                        wobbleTick = false
                    }
                }
            }
            // N9：NavigationStack 容器背景必须透明，否则盖住底层壁纸层。
            .background(.clear)
        }
    }

    private var assistantSection: some View {
        Group {
            if let assistantViewModel {
                VoiceAssistantCardSlot(content: VoiceAssistantCardView(viewModel: assistantViewModel, settingsStore: settings))
            } else {
                VoiceAssistantCardSlot()
            }
        }
        .padding(.horizontal, 16)
        .overlay(alignment: .bottomTrailing) {
            if let onOpenRealtimeVoice {
                Button(action: onOpenRealtimeVoice) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                .padding(14)
                .accessibilityLabel("实时语音")
            }
        }
    }

    // MARK: - 卡片区

    /// 「常用卡片」区：卡片网格 + 编辑态头部（提示 / 完成按钮）。
    private var cardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("常用卡片")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(isEditingCards ? "拖动排序 · 点角标调大小 · 点空白完成" : "长按卡片快捷操作 · 点右上角编辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isEditingCards {
                    Button("完成") {
                        withAnimation(.easeOut(duration: 0.2)) { isEditingCards = false }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.openClawRed)
                } else {
                    Button {
                        withAnimation(.easeIn(duration: 0.15)) { isEditingCards = true }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.openClawRed)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color(.systemGray5)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑卡片")
                    Button {
                        isManagingCards = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.openClawRed)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color(.systemGray5)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("管理卡片")
                }
            }

            cardGrid
        }
        .sheet(isPresented: $isManagingCards) {
            HomeCardManagerView()
        }
        .padding(.horizontal, 16)
    }

    /// C9：合并各 Store 的 objectWillChange，驱动卡面实时数据/角标刷新。
    private var storeRefreshPublisher: AnyPublisher<Void, Never> {
        var publishers: [AnyPublisher<Void, Never>] = [
            careStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            habitStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            geofenceStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            expenseStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            memoryStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            travelStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            kbStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            fileVaultStore.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
        ]
        if let diaryViewModel {
            publishers.append(diaryViewModel.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        }
        return Publishers.MergeMany(publishers).eraseToAnyPublisher()
    }

    /// 可配置卡片网格（S10：编辑态拖动排序 + 尺寸调整；全部移除后一键恢复）。
    private var cardGrid: some View {
        let kinds = HomeCardRegistry.enabledKinds(from: enabledCardKindsStorage)
        return Group {
            if kinds.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("主页卡片已全部移除")
                        .font(.subheadline.weight(.medium))
                    Text("长按卡片进入编辑可移除；这里可一键恢复全部")
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
                ZStack(alignment: .top) {
                    // 编辑态：点空白区域退出编辑（卡片在上层，不受影响）
                    if isEditingCards {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeOut(duration: 0.2)) { isEditingCards = false }
                            }
                            .frame(minHeight: 320)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(kinds) { kind in
                            cardCell(for: kind)
                        }
                    }
                    .task { expenseStore.reload() }
                    .onReceive(storeRefreshPublisher) { _ in storeRefreshTick += 1 }
                }
            }
        }
    }

    /// 卡片跨列数：大卡占满整行（全部列），中卡小卡各占 1 列（一行 2 个）。
    private func gridSpan(for size: HomeCardSize) -> Int {
        size.gridColumns >= 4 ? columns.count : 1
    }

    /// 单个卡片单元：编辑态 = 可拖动 / 移除 × / 尺寸切换；普通态 = 导航链接。
    @ViewBuilder
    private func cardCell(for kind: HomeCardKind) -> some View {
        let size = HomeCardRegistry.size(for: kind, storage: cardSizesStorage)

        if isEditingCards {
            cardContent(for: kind, size: size)
                    .overlay(alignment: .topLeading) {
                    removeOverlay(kind)
                }
                .overlay(alignment: .bottomTrailing) {
                    sizeOverlay(kind)
                }
                .overlay {
                    if targetedKind == kind {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.openClawRed, lineWidth: 2)
                    }
                }
                .rotationEffect(.degrees(wobbleTick ? 0.6 : -0.6))
                .scaleEffect(0.97)
                .animation(.easeInOut(duration: 0.28).repeatForever(autoreverses: true), value: wobbleTick)
                .draggable(kind) {
                    dragPreview(for: kind, size: size)
                }
                .dropDestination(for: HomeCardKind.self) { items, _ in
                    guard let dragged = items.first, dragged != kind else { return false }
                    enabledCardKindsStorage = HomeCardRegistry.moving(dragged, before: kind, in: enabledCardKindsStorage)
                    return true
                } isTargeted: { targeted in
                    withAnimation(.easeOut(duration: 0.15)) {
                        targetedKind = targeted ? kind : nil
                    }
                }
                .gridCellColumns(gridSpan(for: size))
        } else {
            NavigationLink {
                destination(for: kind, size: size)
            } label: {
                cardContent(for: kind, size: size)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开\(kind.title)功能页")
            .contextMenu {
                ForEach(quickActions(for: kind)) { action in
                    NavigationLink(destination: action.destination()) {
                        Label(action.title, systemImage: action.icon)
                    }
                }
            }
            .gridCellColumns(gridSpan(for: size))
        }
    }

    /// 卡片内容（S10：统一 HomeMergedCard 视觉，含记忆卡）。
    private func cardContent(for kind: HomeCardKind, size: HomeCardSize) -> some View {
        HomeMergedCard(
            kind: kind,
            settings: settings,
            careStore: careStore,
            habitStore: habitStore,
            geofenceStore: geofenceStore,
            expenseStore: expenseStore,
            gatewayConnection: gatewayConnection,
            size: size,
            badge: badgeText(for: kind),
            liveSummary: liveSummary(for: kind),
            redDotCount: redDotCount(for: kind)
        )
    }

    /// 卡片目标页：「我的记忆」直达记忆中心；其余进合并卡详情页。
    @ViewBuilder
    private func destination(for kind: HomeCardKind, size: HomeCardSize) -> some View {
        if kind == .memory {
            MemoryHubView(settings: settings, gatewayConnection: gatewayConnection)
        } else if kind == .cloneTalk {
            CloneTalkView(settingsStore: settings)
        } else if kind == .expense {
            ExpenseListView(settingsStore: settings)
        } else if kind == .automation {
            AutomationListView(settings: settings)
        } else if kind == .fileSafe {
            FileVaultView()
        } else if kind == .emergency {
            EmergencyView(store: EmergencyStore.shared)
        } else if kind == .winddown {
            WindDownView(settings: settings)
        } else {
            HomeMergedCardPage(
                kind: kind,
                settings: settings,
                careStore: careStore,
                habitStore: habitStore,
                geofenceStore: geofenceStore,
                expenseStore: expenseStore,
                gatewayConnection: gatewayConnection
            )
        }
    }

    /// 编辑态：左上角移除按钮。
    private func removeOverlay(_ kind: HomeCardKind) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                enabledCardKindsStorage = HomeCardRegistry.removing(kind, from: enabledCardKindsStorage)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.red, in: Circle())
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
        }
        .padding(8)
        .accessibilityLabel("移除\(kind.title)卡片")
    }

    /// 编辑态：右下角尺寸循环按钮（小 → 中 → 大 → 小）。
    private func sizeOverlay(_ kind: HomeCardKind) -> some View {
        Button {
            let current = HomeCardRegistry.size(for: kind, storage: cardSizesStorage)
            cardSizesStorage = HomeCardRegistry.settingSize(current.next, for: kind, in: cardSizesStorage)
        } label: {
            Text(HomeCardRegistry.size(for: kind, storage: cardSizesStorage).shortName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.45), in: Capsule())
        }
        .padding(8)
        .accessibilityLabel("调整\(kind.title)卡片尺寸")
    }

    /// 拖拽预览（编辑态拖动时显示的浮层卡片）。
    private func dragPreview(for kind: HomeCardKind, size: HomeCardSize) -> some View {
        cardContent(for: kind, size: size)
            .frame(width: dragPreviewWidth(for: size))
    }

    private func dragPreviewWidth(for size: HomeCardSize) -> CGFloat {
        switch size {
        case .small: return 140
        case .medium: return 300
        case .large: return 600
        }
    }

    /// S10：老用户存储迁移——「我的记忆」并入网格并置于今日概览下方第一格（一次性）。
    private func migrateCardStorageIfNeeded() {
        var stored = enabledCardKindsStorage
        HomeCardRegistry.runMigrations(&stored)
        if stored != enabledCardKindsStorage {
            enabledCardKindsStorage = stored
        }
    }

    // MARK: - 壁纸层

    /// 主页主题壁纸层（B5/N9）：默认无壁纸 = 系统纯色（深浅色自适应）；
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
                    // S11：全局毛玻璃开启时，壁纸上覆盖磨砂材质（配合壁纸效果最佳）。
                    if settings.settings.globalGlassEnabled {
                        Rectangle().fill(.ultraThinMaterial)
                    }
                } else {
                    // S11：全局毛玻璃开 = 磨砂材质背景；关 = 系统纯色。
                    Rectangle()
                        .fill(HomeWallpaper.glassBackground(enabled: settings.settings.globalGlassEnabled))
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - 今日概览

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
                    tint: .orange,
                    glassEnabled: settings.settings.globalGlassEnabled
                )
                OverviewStatCard(
                    title: "今日日记",
                    value: "\(todayDiaryCount)",
                    icon: "book.fill",
                    tint: .pink,
                    glassEnabled: settings.settings.globalGlassEnabled
                )
                OverviewStatCard(
                    title: "待办",
                    value: "\(todayTodoCount)",
                    icon: "checklist",
                    tint: .green,
                    glassEnabled: settings.settings.globalGlassEnabled
                )
                OverviewStatCard(
                    title: "下次执行",
                    value: automationNextRunText,
                    icon: "bolt.fill",
                    tint: .blue,
                    glassEnabled: settings.settings.globalGlassEnabled
                )
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 数据源

    /// 卡片实时徽标（与各 Store 共用同一数据源；无数据时返回 nil 显示纯卡片）。
    private func badgeText(for kind: HomeCardKind) -> String? {
        switch kind {
        case .expense:
            let summary = expenseStore.monthSummary()
            if summary.expense > 0 { return "¥\(summary.expense.expenseAmountText)" }
            if summary.income > 0 { return "¥\(summary.income.expenseAmountText)" }
            return nil
        case .automation:
            let count = automationViewModel?.tasks.count ?? 0
            return count > 0 ? "\(count) 个任务" : nil
        default:
            return nil
        }
    }

    /// C9：卡面实时摘要——全部来自宿主现有 Store 的真实数据；数据拿不到时显示诚实空态，绝不编造。
    private func liveSummary(for kind: HomeCardKind) -> String? {
        switch kind {
        case .memory:
            let count = memoryStore.profiles.count
            return count > 0 ? "\(count) 条档案" : "暂无档案"
        case .cloneTalk:
            let count = memoryStore.profiles.count
            return count > 0 ? "\(count) 份档案可仿写" : "暂无档案"
        case .record:
            let count = diaryViewModel?.entries.count ?? 0
            return count > 0 ? "共 \(count) 条记录" : "暂无记录"
        case .reminders:
            let count = careStore.todayReminderCount
            return count > 0 ? "今日 \(count) 条待处理" : "今日无提醒"
        case .health:
            if let steps = healthViewModel?.todaySteps {
                return "今日 \(steps) 步"
            }
            return "暂无健康数据"
        case .report:
            // 报告按需生成、无持久化存档 → 诚实空态
            return "按需生成 · 暂无存档"
        case .expense:
            let summary = expenseStore.monthSummary()
            if summary.expense > 0 { return "本月支出 ¥\(summary.expense.expenseAmountText)" }
            if summary.income > 0 { return "本月收入 ¥\(summary.income.expenseAmountText)" }
            return "暂无账目"
        case .travel:
            let upcoming = travelStore.trips
                .filter { $0.periodEndDate >= Date() }
                .sorted { $0.departureDate < $1.departureDate }
            if let next = upcoming.first {
                return "下一程 \(next.destination)"
            }
            return travelStore.trips.isEmpty ? "暂无行程" : "近期无行程"
        case .knowledge:
            let count = kbStore.totalCount
            return count > 0 ? "\(count) 次问答" : "暂无问答"
        case .keyboard:
            // 主 App 无法可靠检测键盘扩展启用状态 → 诚实引导文案
            return "请在系统键盘设置中启用"
        case .automation:
            let enabled = automationViewModel?.tasks.filter(\.enabled).count ?? 0
            if enabled > 0 { return "\(enabled) 个已启用" }
            return (automationViewModel?.tasks.isEmpty ?? true) ? "暂无任务" : "未启用任务"
        case .fileSafe:
            let count = fileVaultStore.files.count
            return count > 0 ? "\(count) 个文件" : "暂无文件"
        case .emergency:
            let config = EmergencyStore.shared.config
            if config.enabled {
                return "已配置 · \(config.emergencyContacts.count) 位联系人"
            }
            return "未配置"
        case .winddown:
            // 与 WindDownView 同一持久化键：已设置睡前提醒 = 已配置
            let configured = UserDefaults.standard.string(forKey: "clawtalk_winddown_reminder_id") != nil
            return configured ? "已设睡前提醒" : "未设置"
        }
    }

    /// C9：红点角标——有未处理数量的卡显示真实计数（如 reminders 今日未完成提醒数）。
    private func redDotCount(for kind: HomeCardKind) -> Int? {
        switch kind {
        case .reminders:
            let count = careStore.todayReminderCount
            return count > 0 ? count : nil
        default:
            return nil
        }
    }

    /// C9：长按快捷动作（2-3 个/卡）——全部跳转宿主现有功能页；无独立子页的动作复用同页导航。
    private func quickActions(for kind: HomeCardKind) -> [HomeCardQuickAction] {
        switch kind {
        case .memory:
            return [
                HomeCardQuickAction(id: "memory.add", title: "添加档案", icon: "plus",
                                    destination: { AnyView(MemoryHubView(settings: settings, gatewayConnection: gatewayConnection)) }),
                HomeCardQuickAction(id: "memory.search", title: "搜索记忆", icon: "magnifyingglass",
                                    destination: { AnyView(MemoryHubView(settings: settings, gatewayConnection: gatewayConnection)) }),
            ]
        case .cloneTalk:
            return [
                HomeCardQuickAction(id: "clone.generate", title: "生成回复", icon: "wand.and.stars",
                                    destination: { AnyView(CloneTalkView(settingsStore: settings)) }),
                HomeCardQuickAction(id: "clone.drafts", title: "查看草稿", icon: "doc.text",
                                    destination: { AnyView(CloneTalkView(settingsStore: settings)) }),
            ]
        case .record:
            return [
                HomeCardQuickAction(id: "record.diary", title: "语音日记", icon: "waveform",
                                    destination: { AnyView(VoiceDiaryView(settingsStore: settings)) }),
                HomeCardQuickAction(id: "record.dictation", title: "文档口述", icon: "doc.plaintext.fill",
                                    destination: { AnyView(DictationListView(settingsStore: settings)) }),
                HomeCardQuickAction(id: "record.meeting", title: "会议纪要", icon: "person.2.fill",
                                    destination: { AnyView(MeetingListView(settingsStore: settings)) }),
            ]
        case .reminders:
            return [
                HomeCardQuickAction(id: "reminders.add", title: "新建提醒", icon: "plus.circle.fill",
                                    destination: { AnyView(ReminderListView(store: careStore, autoOpenAdd: true)) }),
                HomeCardQuickAction(id: "reminders.list", title: "提醒列表", icon: "bell.badge.fill",
                                    destination: { AnyView(ReminderListView(store: careStore)) }),
                HomeCardQuickAction(id: "reminders.anniversary", title: "纪念日", icon: "gift.fill",
                                    destination: { AnyView(AnniversariesView()) }),
            ]
        case .health:
            return [
                HomeCardQuickAction(id: "health.today", title: "今日概览", icon: "heart.fill",
                                    destination: { AnyView(HealthDetailView(viewModel: HealthViewModel())) }),
                HomeCardQuickAction(id: "health.habit", title: "习惯打卡", icon: "checkmark.circle.fill",
                                    destination: { AnyView(HabitsView(store: habitStore)) }),
                HomeCardQuickAction(id: "health.report", title: "健康周报", icon: "heart.text.square.fill",
                                    destination: { AnyView(HealthReportView(healthViewModel: HealthViewModel(), careReminderStore: careStore)) }),
            ]
        case .report:
            return [
                HomeCardQuickAction(id: "report.briefing", title: "每日播报", icon: "sun.max.fill",
                                    destination: { AnyView(DailyBriefingView(settings: settings, careStore: careStore)) }),
                HomeCardQuickAction(id: "report.period", title: "周报月报", icon: "chart.bar.fill",
                                    destination: { AnyView(ReportView(settings: settings)) }),
            ]
        case .expense:
            return [
                HomeCardQuickAction(id: "expense.quick", title: "快速记账", icon: "yensign.circle.fill",
                                    destination: { AnyView(ExpenseListView(settingsStore: settings)) }),
                HomeCardQuickAction(id: "expense.month", title: "本月统计", icon: "chart.pie.fill",
                                    destination: { AnyView(ExpenseListView(settingsStore: settings)) }),
            ]
        case .travel:
            return [
                HomeCardQuickAction(id: "travel.add", title: "新建行程", icon: "plus",
                                    destination: { AnyView(TravelListView(settings: settings)) }),
                HomeCardQuickAction(id: "travel.parking", title: "停车位置", icon: "parkingsign.circle.fill",
                                    destination: { AnyView(ParkingView()) }),
            ]
        case .knowledge:
            return [
                HomeCardQuickAction(id: "knowledge.ask", title: "知识库问答", icon: "books.vertical.fill",
                                    destination: { AnyView(KBView(settings: settings, gatewayConnection: gatewayConnection)) }),
                HomeCardQuickAction(id: "knowledge.summary", title: "长文摘要", icon: "text.badge.checkmark",
                                    destination: { AnyView(SummarizeView(settingsStore: settings)) }),
            ]
        case .keyboard:
            return [
                HomeCardQuickAction(id: "keyboard.now", title: "Now ClawTalk", icon: "brain.head.profile",
                                    destination: { AnyView(ClawTalkPanelHost()) }),
                HomeCardQuickAction(id: "keyboard.insight", title: "每日洞察", icon: "sparkles",
                                    destination: { AnyView(AutoInsightPanelHost()) }),
                HomeCardQuickAction(id: "keyboard.freq", title: "智能调频", icon: "bolt.fill",
                                    destination: { AnyView(SmartFreqPanelHost()) }),
            ]
        case .automation:
            return [
                HomeCardQuickAction(id: "automation.add", title: "新建自动化", icon: "plus",
                                    destination: { AnyView(AutomationListView(settings: settings)) }),
                HomeCardQuickAction(id: "automation.list", title: "任务列表", icon: "clock.badge.checkmark",
                                    destination: { AnyView(AutomationListView(settings: settings)) }),
            ]
        case .fileSafe:
            return [
                HomeCardQuickAction(id: "fileSafe.add", title: "添加文件", icon: "plus",
                                    destination: { AnyView(FileVaultView()) }),
                HomeCardQuickAction(id: "fileSafe.list", title: "防丢登记", icon: "lock.doc.fill",
                                    destination: { AnyView(FileVaultView()) }),
            ]
        case .emergency:
            return [
                HomeCardQuickAction(id: "emergency.contacts", title: "配置紧急联系人", icon: "person.crop.circle.badge.plus",
                                    destination: { AnyView(EmergencyView(store: EmergencyStore.shared)) }),
                HomeCardQuickAction(id: "emergency.sos", title: "SOS 设置", icon: "sos.circle.fill",
                                    destination: { AnyView(EmergencyView(store: EmergencyStore.shared)) }),
            ]
        case .winddown:
            return [
                HomeCardQuickAction(id: "winddown.start", title: "开始助眠", icon: "moon.stars.fill",
                                    destination: { AnyView(WindDownView(settings: settings)) }),
                HomeCardQuickAction(id: "winddown.noise", title: "白噪音", icon: "waveform",
                                    destination: { AnyView(WindDownView(settings: settings)) }),
            ]
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

    /// 今日概览接线：创建自动化数据源（本地任务实时读取；网关 cron 排程后回填 nextRunAt）；
    /// J3：同时创建语音日记数据源（今日日记数/待办数，与日记页同一份本地持久化）。
    private func configureOverviewIfNeeded() {
        guard automationViewModel == nil else { return }
        automationViewModel = AutomationViewModel(settings: settings)
        if diaryViewModel == nil {
            diaryViewModel = VoiceDiaryViewModel(settingsStore: settings, careReminderStore: careStore)
        }
    }

    /// C9：健康数据源接线（异步加载；未授权/失败时保持 nil，卡片显示诚实空态）。
    private func configureHealthIfNeeded() async {
        guard healthViewModel == nil else { return }
        let vm = HealthViewModel()
        await vm.loadIfNeeded()
        healthViewModel = vm
    }

    /// D12：静态缓存 DateFormatter，避免每次渲染新建（卡顿优化）。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func timeText(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

/// 今日概览小统计卡：图标 + 数值 + 标签，横向四连排布（S10：毛玻璃材质）。
private struct OverviewStatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    /// S11：全局毛玻璃开关——开=磨砂卡片；关=纯色卡片底。
    let glassEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
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
                .fill(HomeWallpaper.glassCardBackground(enabled: glassEnabled))
        )
    }
}

/// C9：长按快捷动作模型（全部指向宿主现有功能页）。
private struct HomeCardQuickAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// 懒构建的目标页：仅在长按菜单展示时才构造视图（避免 body 求值预构建 → 主线程阻塞黑屏）。
    let destination: () -> AnyView
}