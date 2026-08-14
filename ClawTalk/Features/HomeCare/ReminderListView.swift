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
    @State private var draftDateTime = Date()
    /// 编辑目标（nil = 新建）；点行进入编辑，预填后保存走 update
    @State private var editingReminder: CareReminder?
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
        VStack(spacing: 0) {
            List {
            Section {
                ForEach(CareReminderStore.defaultTemplates) { template in
                    Button {
                        applyTemplate(template)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: templateIcon(template.category))
                                .font(.headline)
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
                    Text("按住底部按钮直接说「明天下午3点提醒我开会」，\n或点右上角「+」手动添加。提醒只保存在本机，不会上传。")
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
                    editingReminder = nil
                    draftTitle = ""
                    draftDateTime = Date()
                    draftCategory = .sedentary
                    draftRepeat = .daily
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.openClawRed)
                }
                .accessibilityLabel("新建提醒")

            }
        }
        .sheet(isPresented: $showAdd) {
            reminderFormSheet
        }
        .alert(item: $voiceAlert) { alert in
            Alert(
                title: Text(alert.kind == .success ? "已创建提醒" : "语音提醒"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
            Divider().opacity(0.3)
            bottomArea
        }
    }

    // MARK: - 底部录音区（与长文摘要页一致）

    private var bottomArea: some View {
        VStack(spacing: 8) {
            if store.notificationPermissionDenied {
                Text("通知权限被关闭，提醒不会响铃。请在系统设置里允许通知。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            GlobalVoiceInputEmbedded(settingsStore: SettingsStore()) { text, _ in
                applyVoiceText(text)
            }
        }
        .padding(.vertical, 10)
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
            .contentShape(Rectangle())
            .onTapGesture {
                startEditing(reminder)
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
        draftDateTime = template.defaultTime
        draftCategory = template.category
        draftRepeat = template.repeatType
        editingReminder = nil
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
                    .font(.headline)
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
            draftDateTime = Date()
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

    /// 点行编辑：预填当前值
    private func startEditing(_ reminder: CareReminder) {
        draftTitle = reminder.title
        draftDateTime = reminder.scheduledDate ?? reminder.time
        draftCategory = reminder.category
        draftRepeat = reminder.repeatType
        editingReminder = reminder
        showAdd = true
    }

    /// 新建/编辑提醒表单（sheet）：标题 + 日期时间 + 类别 + 重复
    private var reminderFormSheet: some View {
        NavigationStack {
            Form {
                Section("提醒内容") {
                    TextField("例如：开会、喝水、吃药", text: $draftTitle)
                }
                Section("时间") {
                    DatePicker("日期与时间", selection: $draftDateTime, displayedComponents: [.date, .hourAndMinute])
                    if draftRepeat == .none {
                        Text("一次性提醒：到点响一次")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("类别") {
                    Picker("类别", selection: $draftCategory) {
                        ForEach(CareReminderCategory.allCases) { category in
                            Text(category.rawValue).tag(category)
                        }
                    }
                }
                Section("重复") {
                    Picker("重复", selection: $draftRepeat) {
                        ForEach(CareReminderRepeat.allCases) { repeatType in
                            Text(repeatType.displayName).tag(repeatType)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle(editingReminder == nil ? "新建提醒" : "编辑提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveDraft() }
                        .fontWeight(.semibold)
                        .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveDraft() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        // 一次性提醒带完整日期；重复提醒只取时:分
        let scheduledDate: Date? = draftRepeat == .none ? draftDateTime : nil
        if let editing = editingReminder {
            store.update(
                CareReminder(
                    id: editing.id,
                    title: title,
                    time: draftDateTime,
                    category: draftCategory,
                    repeatType: draftRepeat,
                    enabled: editing.enabled,
                    scheduledDate: scheduledDate,
                    createdAt: editing.createdAt
                )
            )
        } else {
            store.add(
                CareReminder(
                    title: title,
                    time: draftDateTime,
                    category: draftCategory,
                    repeatType: draftRepeat,
                    scheduledDate: scheduledDate
                )
            )
        }
        draftTitle = ""
        draftDateTime = Date()
        draftCategory = .sedentary
        draftRepeat = .daily
        editingReminder = nil
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
