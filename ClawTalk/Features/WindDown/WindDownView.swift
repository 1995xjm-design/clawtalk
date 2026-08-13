import SwiftUI

/// 「睡前陪伴」页：顶部大「说晚安」按钮（TTS 温柔朗读全文）+
/// 播报文案全文 + 今日总结 / 明日预告分区 + 助眠引导（4-7-8 呼吸动画）+
/// 可选「每日定时睡前提醒」（存 CareReminderStore，daily 提醒）。
///
/// 数据源：WindDownEngine 聚合；失败 / 未授权降级跳过并在分区如实标注。
/// TTS：与 ClawTalkApp.configureServices 同规则创建 SpeechService
/// （默认 AppleTTSService(speed:pitch:)），PCM 音频流走 AudioPlaybackManager。
/// 温柔朗读：语速在用户设置基础上放慢（speed - 15）；夜间时段（21:00–06:00）
/// 或用户语音助手场景为夜间时调用 duckVolume（音量 0.3，参考 VoiceSceneMode.quietVoice）。
/// 每次播报新建 TTS 实例：AppleTTSService.stop() 会把实例永久置 stopped，
/// 复用旧实例会导致后续朗读静音（与 DailyBriefingView 同思路，不缓存）。
///
/// 主智能体接线：
/// - 主页卡：WindDownCardView()（自带 NavigationLink 进本页）
/// - 独立入口：NavigationStack { WindDownView(settings: settingsStore) }
struct WindDownView: View {
    private let settings: SettingsStore

    @State private var careStore: CareReminderStore
    @State private var diaryViewModel: VoiceDiaryViewModel
    @State private var habitStore: HabitStore
    @State private var engine: WindDownEngine

    @State private var content: WindDownEngine.Content?
    @State private var isLoading = false

    // MARK: - 播报播放状态

    @State private var isSpeaking = false
    @State private var speechError: String?
    @State private var speechTask: Task<Void, Never>?
    @State private var speechService: (any SpeechService)?
    @State private var audioPlayback = AudioPlaybackManager()
    @StateObject private var noisePlayer = WindDownNoisePlayer()


    // MARK: - 白噪音

    private var noiseSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { noisePlayer.isPlaying },
                set: { newValue in
                    if newValue {
                        noisePlayer.start()
                    } else {
                        noisePlayer.stop()
                    }
                }
            )) {
                Label("播放白噪音", systemImage: "speaker.wave.2.fill")
            }
            .tint(.indigo)

            if noisePlayer.isPlaying {
                HStack {
                    ForEach([15, 30, 60], id: \.self) { minutes in
                        Button {
                            noisePlayer.startTimed(minutes: minutes)
                        } label: {
                            Text(minutes == 15 ? "15 分钟" : (minutes == 30 ? "30 分钟" : "60 分钟"))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.indigo.opacity(0.14), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if let remaining = noisePlayer.remainingMinutes {
                    Text("定时停止：还剩 \(remaining) 分钟")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label("白噪音", systemImage: "moon.zzz.fill")
        } footer: {
            Text("纯代码生成的轻柔白噪音循环，可定时停止；与「说晚安」朗读互不影响。")
        }
    }

    // MARK: - 每日定时睡前提醒（可选）

    @State private var reminderEnabled = false
    @State private var reminderTime: Date

    private static let windDownReminderIDKey = "clawtalk_winddown_reminder_id"
    private static let windDownReminderTitle = "睡前陪伴"

    init(
        settings: SettingsStore? = nil,
        careStore: CareReminderStore? = nil,
        diaryViewModel: VoiceDiaryViewModel? = nil,
        habitStore: HabitStore? = nil
    ) {
        let resolvedSettings = settings ?? SettingsStore()
        let resolvedCare = careStore ?? CareReminderStore()
        let resolvedDiary = diaryViewModel ?? VoiceDiaryViewModel(settingsStore: resolvedSettings)
        let resolvedHabits = habitStore ?? HabitStore(careReminderStore: resolvedCare)
        self.settings = resolvedSettings
        _careStore = State(initialValue: resolvedCare)
        _diaryViewModel = State(initialValue: resolvedDiary)
        _habitStore = State(initialValue: resolvedHabits)
        _engine = State(initialValue: WindDownEngine(
            careStore: resolvedCare,
            diaryViewModel: resolvedDiary,
            habitStore: resolvedHabits
        ))

        // 恢复已保存的定时睡前提醒
        let storedID = UserDefaults.standard.string(forKey: Self.windDownReminderIDKey)
        let storedReminder = storedID.flatMap { id in
            resolvedCare.reminders.first { $0.id == id }
        }
        _reminderEnabled = State(initialValue: storedReminder != nil)
        _reminderTime = State(initialValue: storedReminder?.time ?? Self.defaultReminderTime)
    }

    var body: some View {
        List {
            Section {
                playButton
                if let speechError {
                    Label(speechError, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("说晚安", systemImage: "moon.stars.fill")
            }

            if let content {
                spokenTextSection(content)
                todaySection(content)
                tomorrowSection(content)
                breathingSection
                noiseSection
                nightlyReminderSection
                skippedSection(content)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("睡前陪伴")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .onDisappear {
            stopSpeaking()
            noisePlayer.stop()
        }
        .overlay(alignment: .bottom) {
            GlobalVoiceInputFloating(settingsStore: settings)
                .padding(.bottom, 20)
        }
    }

    // MARK: - 说晚安（TTS 温柔朗读）

    private var playButton: some View {
        Button {
            if isSpeaking {
                stopSpeaking()
            } else {
                startSpeaking()
            }
        } label: {
            Label(
                isSpeaking ? "停止播放" : "说晚安",
                systemImage: isSpeaking ? "stop.circle.fill" : "moon.zzz.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                isSpeaking ? Color.red : Color.indigo,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || content?.spokenText.isEmpty ?? true)
    }

    private func startSpeaking() {
        guard let content, !content.spokenText.isEmpty else { return }
        stopSpeaking()

        let tts = makeSpeechService()
        speechService = tts
        do {
            try audioPlayback.start()
        } catch {
            speechError = "语音播报启动失败：\(AppErrorText.localized(error.localizedDescription))"
            return
        }

        // 夜间轻声：当前处于夜间时段或用户语音助手场景为夜间时降低音量
        if usesQuietVoice {
            audioPlayback.duckVolume()
        }

        isSpeaking = true
        speechError = nil
        speechTask = Task { @MainActor in
            defer { isSpeaking = false }
            do {
                for try await chunk in tts.streamSpeech(text: content.spokenText) {
                    try Task.checkCancellation()
                    audioPlayback.enqueue(pcmData: chunk)
                }
                audioPlayback.markStreamingDone()
                await audioPlayback.waitUntilFinished()
            } catch is CancellationError {
                // 用户点了停止：静默结束
            } catch {
                LogCollector.record(module: "睡前陪伴", "朗读失败：\(AppErrorText.localized(error.localizedDescription))")
            }
            audioPlayback.stop()
        }
    }

    private func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        speechService?.stop()
        speechService = nil
        audioPlayback.stop()
        isSpeaking = false
    }

    /// 温柔朗读：在用户设置基础上放慢语速（speed - 15）、略微抬高音调（pitch + 5）。
    private func makeSpeechService() -> any SpeechService {
        let s = settings.settings
        let gentleSpeed = max(-50, s.ttsSpeed - 15)
        let gentlePitch = s.ttsPitch + 5
        switch s.ttsProvider {
        case .apple:
            return AppleTTSService(speed: gentleSpeed, pitch: gentlePitch)
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                return DoubaoTTSService(apiKey: key, voiceID: s.doubaoVoiceID)
            }
            return AppleTTSService(speed: gentleSpeed, pitch: gentlePitch)
        case .edge:
            return EdgeTTSService(voiceID: s.edgeVoiceID, speed: gentleSpeed, pitch: gentlePitch)
        }
    }

    /// 夜间轻声判断：21:00–06:00，或语音助手场景模式持久化为夜间（读取既有 UserDefaults）。
    private var usesQuietVoice: Bool {
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 21 || hour < 6 { return true }
        if let raw = UserDefaults.standard.string(forKey: "voiceAssistant.sceneMode"),
           let mode = VoiceSceneMode(rawValue: raw) {
            return mode.usesQuietVoice
        }
        return false
    }

    // MARK: - 加载

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        speechError = nil
        content = await engine.build()
    }

    // MARK: - 播报文案

    private func spokenTextSection(_ content: WindDownEngine.Content) -> some View {
        Section {
            Text(content.spokenText)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } header: {
            Label("今晚的晚安", systemImage: "text.quote")
        }
    }

    // MARK: - 今日总结

    private func todaySection(_ content: WindDownEngine.Content) -> some View {
        Section {
            if let note = content.skippedNotes.first(where: { $0.section == "今日日记" }) {
                emptyRow("日记未接入", detail: note.message)
            } else if let count = content.diaryCount {
                Label(count > 0 ? "今天记了 \(count) 篇日记" : "今天没有记日记", systemImage: "book.fill")
                    .foregroundStyle(.primary)
            }

            if let count = content.completedReminderCount {
                Label(count > 0 ? "今天有 \(count) 条提醒已经到点" : "今天没有已到点的提醒", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
            }

            if let note = content.skippedNotes.first(where: { $0.section == "习惯打卡" }) {
                emptyRow("习惯打卡未接入", detail: note.message)
            } else if content.habitDueCount > 0 {
                Label("习惯打卡 \(content.habitCompletedCount)/\(content.habitDueCount)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.primary)
            } else {
                Label("今天没有要打卡的习惯", systemImage: "checkmark.seal")
                    .foregroundStyle(.primary)
            }
        } header: {
            Label("今日总结", systemImage: "sun.horizon")
        } footer: {
            if content.completedReminderCount != nil {
                Text("「已到点」指今天的触发时刻已过，视为已完成。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 明日预告

    private func tomorrowSection(_ content: WindDownEngine.Content) -> some View {
        Section {
            if let note = content.skippedNotes.first(where: { $0.section == "明日提醒" }) {
                emptyRow("提醒未接入", detail: note.message)
            } else if content.tomorrowReminderCount == 0 {
                emptyRow("明天没有要响的提醒", detail: "在「提醒」里创建的居家提醒会显示在这里")
            } else {
                ForEach(content.tomorrowReminderItems) { item in
                    NavigationLink {
                        ReminderListView(store: careStore)
                    } label: {
                        briefRow(item)
                    }
                }
                if content.tomorrowReminderCount > content.tomorrowReminderItems.count {
                    Text("另有 \(content.tomorrowReminderCount - content.tomorrowReminderItems.count) 条，详见提醒列表")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let note = content.skippedNotes.first(where: { $0.section == "明日待办" }) {
                emptyRow("待办已跳过", detail: note.message)
            } else if content.tomorrowTodoCount == 0 {
                emptyRow("明天没有待办", detail: "提醒事项里没有安排到明天的事项")
            } else {
                ForEach(content.tomorrowTodoItems) { item in
                    briefRow(item)
                }
                if content.tomorrowTodoCount > content.tomorrowTodoItems.count {
                    Text("另有 \(content.tomorrowTodoCount - content.tomorrowTodoItems.count) 件待办")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            if let note = content.skippedNotes.first(where: { $0.section == "明日日程" }) {
                emptyRow("日程已跳过", detail: note.message)
            } else if content.tomorrowScheduleCount == 0 {
                emptyRow("明天没有日程", detail: "日历里没有安排，好好休息")
            } else {
                ForEach(content.tomorrowScheduleItems) { item in
                    briefRow(item)
                }
                if content.tomorrowScheduleCount > content.tomorrowScheduleItems.count {
                    Text("另有 \(content.tomorrowScheduleCount - content.tomorrowScheduleItems.count) 个日程")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Label("明日预告", systemImage: "calendar.badge.clock")
        }
    }

    // MARK: - 助眠引导（4-7-8 呼吸）

    private var breathingSection: some View {
        Section {
            BreathingGuideView()
        } header: {
            Label("助眠引导", systemImage: "wind")
        } footer: {
            Text("跟着圆圈呼吸：吸气 4 秒圆圈放大，屏住 7 秒保持，呼气 8 秒圆圈缩小。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }




    // MARK: - 每日定时睡前提醒（可选）

    private var nightlyReminderSection: some View {
        Section {
            Toggle(
                "每天晚上提醒我做睡前陪伴",
                isOn: Binding(
                    get: { reminderEnabled },
                    set: { toggleReminder($0) }
                )
            )
            if reminderEnabled {
                DatePicker(
                    "提醒时间",
                    selection: Binding(
                        get: { reminderTime },
                        set: { newValue in
                            reminderTime = newValue
                            updateReminderTime()
                        }
                    ),
                    displayedComponents: .hourAndMinute
                )
            }
            if careStore.notificationPermissionDenied {
                Label("通知权限被系统拒绝，提醒会保存但到点不会响铃。请到系统设置开启通知。", systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Label("每日定时提醒", systemImage: "alarm")
        } footer: {
            Text("开启后保存为 CareReminderStore 的一条每天提醒（默认 22:30），到点由本地通知提醒做睡前陪伴。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func toggleReminder(_ enabled: Bool) {
        reminderEnabled = enabled
        if enabled {
            let reminder = CareReminder(
                title: Self.windDownReminderTitle,
                time: reminderTime,
                category: .custom,
                repeatType: .daily,
                enabled: true
            )
            let added = careStore.add(reminder)
            UserDefaults.standard.set(added.id, forKey: Self.windDownReminderIDKey)
        } else {
            if let id = UserDefaults.standard.string(forKey: Self.windDownReminderIDKey) {
                careStore.delete(id: id)
            }
            UserDefaults.standard.removeObject(forKey: Self.windDownReminderIDKey)
        }
    }

    private func updateReminderTime() {
        guard reminderEnabled,
              let id = UserDefaults.standard.string(forKey: Self.windDownReminderIDKey),
              let index = careStore.reminders.firstIndex(where: { $0.id == id }) else {
            return
        }
        var reminder = careStore.reminders[index]
        reminder.time = reminderTime
        careStore.update(reminder)
    }

    /// 默认提醒时间：22:30。
    private static var defaultReminderTime: Date {
        Calendar.current.date(bySettingHour: 22, minute: 30, second: 0, of: Date()) ?? Date()
    }

    // MARK: - 未读取数据说明

    @ViewBuilder
    private func skippedSection(_ content: WindDownEngine.Content) -> some View {
        if !content.skippedNotes.isEmpty {
            Section {
                ForEach(content.skippedNotes) { note in
                    Label(note.message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("本次未读取的数据", systemImage: "exclamationmark.triangle")
            }
        }
    }

    // MARK: - 通用

    private func briefRow(_ item: WindDownEngine.BriefItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let timeText = item.timeText {
                Text(timeText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func emptyRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

/// 「助眠引导」：4-7-8 呼吸法圆圈缩放动画（纯 SwiftUI）。
/// 节奏：吸气 4 秒（圆圈放大）→ 屏住 7 秒（保持）→ 呼气 8 秒（圆圈缩小），循环进行。
private struct BreathingGuideView: View {
    private enum Phase: String {
        case inhale = "吸气"
        case hold = "屏住"
        case exhale = "呼气"

        var duration: Double {
            switch self {
            case .inhale: return 4
            case .hold: return 7
            case .exhale: return 8
            }
        }
    }

    @State private var phase: Phase = .inhale
    @State private var phaseStartedAt: Date = .now
    @State private var isRunning = false
    @State private var round = 0
    @State private var task: Task<Void, Never>?

    private var scale: CGFloat {
        switch phase {
        case .inhale, .hold: return 1.35
        case .exhale: return 1.0
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.indigo.opacity(0.18), lineWidth: 4)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.indigo.opacity(0.5), Color.purple.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 150, height: 150)
                    .scaleEffect(scale)
                    .animation(
                        phase == .hold ? .none : .easeInOut(duration: phase.duration),
                        value: scale
                    )
                VStack(spacing: 4) {
                    if isRunning {
                        Text(phase.rawValue)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let remaining = max(
                                0,
                                Int(ceil(phase.duration - context.date.timeIntervalSince(phaseStartedAt)))
                            )
                            Text("\(remaining)")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    } else {
                        Text("准备好了吗")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 220, height: 220)

            Text("4-7-8 呼吸法：吸气 4 秒 → 屏住 7 秒 → 呼气 8 秒")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if isRunning {
                Text("第 \(round) 轮")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                if isRunning {
                    stop()
                } else {
                    start()
                }
            } label: {
                Label(
                    isRunning ? "停止引导" : "开始助眠引导",
                    systemImage: isRunning ? "stop.circle.fill" : "moon.zzz.fill"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    isRunning ? Color.orange : Color.indigo,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRunning = true
        round = 1
        phase = .inhale
        phaseStartedAt = .now
        task?.cancel()
        task = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(phase.duration * 1_000_000_000))
                guard !Task.isCancelled else { break }
                switch phase {
                case .inhale:
                    phase = .hold
                case .hold:
                    phase = .exhale
                case .exhale:
                    phase = .inhale
                    round += 1
                }
                phaseStartedAt = .now
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        round = 0
        phase = .inhale
    }
}
