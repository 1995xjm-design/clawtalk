import SwiftUI

/// 提醒列表页：按时间排序，每条显示时间 / 标题 / 类别徽章 / 启用开关。
/// 顶部「按住说话新建提醒」：按住录音（AudioCaptureManager）→ STT 转写（AppleSTTService）
/// → VoiceReminderParser 解析「明天下午3点提醒我开会」→ 自动填标题+时间
/// 存入 CareReminderStore 并排本地通知；解析不出时间自动弹手动填写（标题预填）。
/// 右上角「+」手动添加入口；空列表诚实空状态；通知权限被拒时列表底部提示。
struct ReminderListView: View {
    @State private var store: CareReminderStore
    @State private var showAdd = false
    @State private var draftTitle = ""
    @State private var draftTime = Date()
    @State private var draftCategory: CareReminderCategory = .sedentary
    @State private var draftRepeat: CareReminderRepeat = .daily

    // 语音输入（复用现有语音栈：AudioCaptureManager + TranscriptionService，只读引用）
    @State private var captureManager = AudioCaptureManager()
    @State private var stt: any TranscriptionService = ReminderListView.makeSTT()
    @State private var isVoiceRecording = false
    @State private var isTranscribing = false
    @State private var voiceAlert: VoiceReminderAlert?

    /// 按 SettingsStore.sttProvider 创建 STT（跟随语音设置里的提供商；无豆包 Key 回退 Apple）
    private static func makeSTT() -> any TranscriptionService {
        let settings = SettingsStore().settings
        if settings.sttProvider == .doubao,
           let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
            return DoubaoSTTService(apiKey: key, language: settings.whisperLanguage)
        }
        return AppleSTTService(language: settings.whisperLanguage)
    }
    init(store: CareReminderStore? = nil, autoOpenAdd: Bool = false) {
        _store = State(initialValue: store ?? CareReminderStore())
        _showAdd = State(initialValue: autoOpenAdd)
    }

    var body: some View {
        List {
            Section {
                holdToTalkRow
            } header: {
                Text(isVoiceRecording ? "正在录音，松手识别" : "按住说话，松手识别")
            }
            Section {
                ForEach(CareReminderStore.defaultTemplates) { template in
                    Button {
                        applyTemplate(template)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: templateIcon(template.category))
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Color.openClawRed)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(template.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text("默认 \(timeText(template.defaultTime)) · \(template.repeatType.displayName)，点按可改时间")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(Color.openClawRed)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Label("快速添加模板", systemImage: "bolt.fill")
            } footer: {
                Text("久坐 / 喝水 / 用药三类常用提醒，点按预填内容与时间，可在弹窗里调整后保存。")
            }

            if store.reminders.isEmpty {
                ContentUnavailableView {
                    Label("暂无提醒", systemImage: "bell.badge")
                } description: {
                    Text("按住上方按钮直接说「明天下午3点提醒我开会」，\n或点右上角「+」手动添加。提醒只保存在本机，不会上传。")
                } actions: {
                    Button("添加提醒") {
                        showAdd = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(store.reminders) { reminder in
                reminderRow(reminder)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(id: reminder.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("提醒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.openClawRed)
                }
            }
        }
        .alert("新建提醒", isPresented: $showAdd) {
            TextField("提醒内容", text: $draftTitle)
            DatePicker("时间", selection: $draftTime, displayedComponents: .hourAndMinute)
            Picker("类别", selection: $draftCategory) {
                ForEach(CareReminderCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            Picker("重复", selection: $draftRepeat) {
                ForEach(CareReminderRepeat.allCases) { repeatType in
                    Text(repeatType.displayName).tag(repeatType)
                }
            }
            Button("保存") {
                saveDraft()
            }
            .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        } message: {
            Text("到点通过本地通知响铃提醒")
        }
        .alert(item: $voiceAlert) { alert in
            Alert(
                title: Text(alert.kind == .success ? "已创建提醒" : "语音提醒"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .safeAreaInset(edge: .bottom) {
            if store.notificationPermissionDenied {
                Text("通知权限被关闭，提醒不会响铃。请在系统设置里允许通知。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
        .overlay(alignment: .bottom) {
            GlobalVoiceInputFloating(settingsStore: SettingsStore())
                .padding(.bottom, 20)
        }
    }

    // MARK: - 行

    private func reminderRow(_ reminder: CareReminder) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(timeLabel(for: reminder))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                    CareReminderBadge(category: reminder.category)
                }
                Text(reminder.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle(for: reminder))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: enabledBinding(for: reminder))
                .labelsHidden()
                .tint(.openClawRed)
        }
        .padding(.vertical, 4)
    }

    /// 一次性提醒显示具体日期（今天/明天/周X），重复提醒显示时:分。
    private func timeLabel(for reminder: CareReminder) -> String {
        if let scheduled = reminder.scheduledDate {
            if Calendar.current.isDateInToday(scheduled) {
                return "今天 \(timeText(scheduled))"
            }
            return "\(dayLabel(scheduled)) \(timeText(scheduled))"
        }
        return timeText(reminder.time)
    }

    private func subtitle(for reminder: CareReminder) -> String {
        if reminder.repeatType == .none, reminder.scheduledDate != nil {
            return "一次"
        }
        return reminder.repeatType.displayName
    }

    private func enabledBinding(for reminder: CareReminder) -> Binding<Bool> {
        Binding(
            get: { reminder.enabled },
            set: { store.setEnabled($0, for: reminder.id) }
        )
    }


    // MARK: - 快速添加模板

    private func applyTemplate(_ template: CareReminderTemplate) {
        draftTitle = template.title
        draftTime = template.defaultTime
        draftCategory = template.category
        draftRepeat = template.repeatType
        showAdd = true
    }

    private func templateIcon(_ category: CareReminderCategory) -> String {
        switch category {
        case .sedentary: return "figure.walk"
        case .water: return "drop.fill"
        case .medication: return "pills.fill"
        case .custom: return "bell.fill"
        }
    }    // MARK: - 按住说话新建提醒

    private var holdToTalkRow: some View {
        Button {} label: {
            HStack(spacing: 12) {
                Image(systemName: isVoiceRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isVoiceRecording ? Color.white : Color.openClawRed)
                    .frame(width: 36, height: 36)
                    .background(isVoiceRecording ? Color.openClawRed : Color.openClawRed.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(holdButtonTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(isVoiceRecording ? "说完松手，自动识别成提醒" : "例如「明天下午3点提醒我开会」")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if isTranscribing {
                    ProgressView()
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isTranscribing)
        .gesture(recordGesture)
    }

    private var holdButtonTitle: String {
        if isVoiceRecording { return "正在录音…" }
        if isTranscribing { return "识别中…" }
        return "按住说话新建提醒"
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isVoiceRecording, !isTranscribing else { return }
                // 与聊天页/语音日记一致：先停语音唤醒，避免两个音频引擎抢麦
                VoiceWakeCapability.shared.stopListening()
                do {
                    try captureManager.startRecording()
                    isVoiceRecording = true
                } catch {
                    voiceAlert = VoiceReminderAlert(
                        kind: .error,
                        message: "无法开始录音：\(AppErrorText.localized(error.localizedDescription))"
                    )
                }
            }
            .onEnded { _ in
                guard isVoiceRecording else { return }
                isVoiceRecording = false
                let samples = captureManager.stopRecording()
                Task { await processRecordedSamples(samples) }
            }
    }

    @MainActor
    private func processRecordedSamples(_ samples: [Float]) async {
        // 与聊天页/语音日记同阈值：约 0.5s（8000 样本 @16kHz）以下视为误触
        guard samples.count > 8000 else {
            restoreWakeListening()
            if !samples.isEmpty {
                voiceAlert = VoiceReminderAlert(kind: .error, message: "录音太短，请按住说完整一句话")
            }
            return
        }

        isTranscribing = true
        defer {
            isTranscribing = false
            restoreWakeListening()
        }

        do {
            let transcript = try await stt.transcribe(audioSamples: samples)
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                voiceAlert = VoiceReminderAlert(kind: .error, message: "没有识别到内容，请再说一遍")
                return
            }
            applyVoiceText(text)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            voiceAlert = VoiceReminderAlert(kind: .error, message: "识别失败：\(detail)")
        }
    }

    /// 语音文本落库：能解析出时间直接创建；解析不出弹手动填写（标题预填）。
    private func applyVoiceText(_ text: String) {
        switch VoiceReminderParser.parse(text) {
        case .success(let draft):
            store.add(
                CareReminder(
                    title: draft.title,
                    time: draft.time,
                    category: draft.category,
                    repeatType: draft.repeatType,
                    scheduledDate: draft.scheduledDate
                )
            )
            voiceAlert = VoiceReminderAlert(
                kind: .success,
                message: "「\(draft.title)」已安排在 \(voiceTimeText(draft))"
            )
        case .failure:
            draftTitle = VoiceReminderParser.extractTitle(from: text)
            draftTime = Date()
            showAdd = true
        }
    }

    private func voiceTimeText(_ draft: VoiceReminderParser.Draft) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        if let scheduledDate = draft.scheduledDate {
            return "\(dayLabel(scheduledDate)) \(formatter.string(from: scheduledDate))"
        }
        return "\(draft.repeatType.displayName) \(formatter.string(from: draft.time))"
    }

    /// 录音/转写结束后恢复语音唤醒监听（App 层已监听该通知，与语音日记一致）。
    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }

    // MARK: - 手动添加

    private func saveDraft() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.add(
            CareReminder(
                title: title,
                time: draftTime,
                category: draftCategory,
                repeatType: draftRepeat
            )
        )
        draftTitle = ""
        draftTime = Date()
        draftCategory = .sedentary
        draftRepeat = .daily
        showAdd = false
    }

    private func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return weekdays[calendar.component(.weekday, from: date) - 1]
    }
}

// MARK: - 语音输入结果弹窗

/// 语音输入反馈（成功/失败各一条消息，诚实反馈不静默）。
struct VoiceReminderAlert: Identifiable {
    enum Kind: Equatable {
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

// MARK: - 类别徽章

/// 提醒类别徽章：类别名 + 图标 + 主题色胶囊背景。
struct CareReminderBadge: View {
    let category: CareReminderCategory

    var body: some View {
        Label(category.rawValue, systemImage: category.iconName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(category.themeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(category.themeColor.opacity(0.14), in: Capsule())
    }
}

extension CareReminderCategory {
    /// 类别图标（SF Symbols）
    var iconName: String {
        switch self {
        case .sedentary: return "figure.seated.side"
        case .water: return "drop.fill"
        case .medication: return "pills.fill"
        case .custom: return "bell.fill"
        }
    }

    /// 类别主题色（浅色/深色下均有对比度）
    var themeColor: Color {
        switch self {
        case .sedentary: return .orange
        case .water: return .blue
        case .medication: return .red
        case .custom: return .purple
        }
    }
}