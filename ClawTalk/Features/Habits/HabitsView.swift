import SwiftUI

/// 习惯列表页：
/// - 每条显示 图标/名称/重复日/今日状态/连续天数 + 今日打卡按钮；
/// - 顶部按住说话语音打卡（复用 AudioCaptureManager + TranscriptionService）；
/// - 「+」新增习惯（alert 填名称/选图标/选重复日，可勾同步每日提醒）；
/// - 行内滑动可编辑（自由勾选周几）与删除；
/// - 无习惯时诚实空状态。
struct HabitsView: View {
    @State private var store: HabitStore
    // 语音输入（复用现有语音栈，只读引用；默认 AppleSTTService，可注入）
    @State private var captureManager = AudioCaptureManager()
    @State private var stt: any TranscriptionService
    @State private var isVoiceRecording = false
    @State private var isTranscribing = false
    @State private var voiceAlert: HabitVoiceAlert?

    // 新增习惯表单
    @State private var showAdd = false
    @State private var draftName = ""
    @State private var draftIcon = "drop.fill"
    @State private var draftRepeat: HabitRepeatPreset = .everyDay
    @State private var draftLinkReminder = true
    @State private var draftReminderTime = HabitStore.defaultReminderTime

    // 编辑（行内滑动进入，自由勾选周几）
    @State private var editingHabit: Habit?

    /// 按 SettingsStore.sttProvider 创建 STT（跟随语音设置里的提供商；无豆包 Key 回退 Apple）
    private static func makeSTT() -> any TranscriptionService {
        let settings = SettingsStore().settings
        if settings.sttProvider == .doubao,
           let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
            return DoubaoSTTService(apiKey: key, language: settings.whisperLanguage)
        }
        return AppleSTTService(language: settings.whisperLanguage)
    }
    init(store: HabitStore? = nil, stt: (any TranscriptionService)? = nil) {
        _store = State(initialValue: store ?? HabitStore())
        _stt = State(initialValue: stt ?? HabitsView.makeSTT())
    }

    var body: some View {
        VStack(spacing: 0) {
            List {

            if !store.habits.isEmpty {
                monthSection
            }

            if store.habits.isEmpty {
                ContentUnavailableView {
                    Label("暂无习惯", systemImage: "checkmark.seal")
                } description: {
                    Text("点右上角「+」添加习惯，比如喝水、运动、早睡、阅读。\n也可以按住底部按钮说「喝水打卡」直接打卡。数据只保存在本机。")
                } actions: {
                    Button("添加习惯") {
                        showAdd = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(store.habits) { habit in
                habitRow(habit)
                    .swipeActions(edge: .trailing) {
                        Button {
                            editingHabit = habit
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.blue)

                        Button(role: .destructive) {
                            store.delete(id: habit.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("习惯打卡")
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
        .alert("新建习惯", isPresented: $showAdd) {
            TextField("习惯名称", text: $draftName)
            Picker("图标", selection: $draftIcon) {
                ForEach(HabitIconOption.allCases) { option in
                    Text(option.label).tag(option.icon)
                }
            }
            Picker("重复日", selection: $draftRepeat) {
                ForEach(HabitRepeatPreset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            Toggle("同步每日提醒", isOn: $draftLinkReminder)
            DatePicker("提醒时间", selection: $draftReminderTime, displayedComponents: .hourAndMinute)
            Button("保存") {
                saveDraft()
            }
            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后将复用提醒功能，在所选时间提醒你打卡（不会重复建通知）")
        }
        .alert(item: $voiceAlert) { alert in
            Alert(
                title: Text(alert.kind == .success ? "打卡成功" : (alert.kind == .info ? "提示" : "语音打卡")),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(item: $editingHabit) { habit in
            HabitEditSheet(habit: habit, store: store)
        }
        .onAppear {
            store.errorMessage = nil
            store.reload()
        }

            Divider().opacity(0.3)
            bottomArea
        }
    }

    // MARK: - 底部录音区（与长文摘要页一致）

    private var bottomArea: some View {
        GlobalVoiceInputEmbedded(settingsStore: SettingsStore()) { text, _ in
            applyVoiceText(text)
        }
        .padding(.vertical, 10)
    }

    // MARK: - 行

    private func habitRow(_ habit: Habit) -> some View {
        HStack(spacing: 12) {
            Image(systemName: habit.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Color.teal, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(habit.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(subtitle(for: habit))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text("连续 \(habit.streak) 天")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(habit.streak > 0 ? Color.orange : Color.secondary)
                checkInButton(habit)
            }
        }
        .padding(.vertical, 4)
    }

    private func subtitle(for habit: Habit) -> String {
        let base: String
        if !habit.isDue(on: Date()) {
            base = "\(habit.repeatSummary) · 今日休息"
        } else if habit.isChecked(on: Date()) {
            base = "\(habit.repeatSummary) · 今日已打卡"
        } else {
            base = "\(habit.repeatSummary) · 今日待打卡"
        }
        let stats = store.monthStats(for: habit)
        return "\(base) · 本月 \(stats.checked)/\(stats.due) 天"
    }

    @ViewBuilder
    private func checkInButton(_ habit: Habit) -> some View {
        if habit.isDue(on: Date()) {
            if habit.isChecked(on: Date()) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.green)
            } else {
                Button {
                    store.checkIn(id: habit.id)
                } label: {
                    Text("打卡")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.openClawRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.openClawRed.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        } else {
            Text("休息")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }


    // MARK: - 本月坚持

    private var monthSection: some View {
        let overview = store.monthOverview()
        return Section {
            LabeledContent("本月打卡", value: "\(overview.checked) / \(overview.due) 天")
            LabeledContent("完成率", value: percentText(overview))
        } header: {
            Label("本月坚持", systemImage: "calendar")
        } footer: {
            Text("按今天为止的应打卡日统计（休息日不计入）；今天的进度会实时变化。")
        }
    }

    private func percentText(_ overview: (checked: Int, due: Int)) -> String {
        guard overview.due > 0 else { return "—" }
        let pct = Int((Double(overview.checked) / Double(overview.due) * 100).rounded())
        return "\(pct)%"
    }    // MARK: - 按住说话打卡

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
                    Text(isVoiceRecording ? "说完松手，自动打卡" : "例如「喝水打卡」「运动打卡」")
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
        return "按住说话打卡"
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
                    voiceAlert = HabitVoiceAlert(
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
                voiceAlert = HabitVoiceAlert(kind: .error, message: "录音太短，请按住说完整一句话")
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
                voiceAlert = HabitVoiceAlert(kind: .error, message: "没有识别到内容，请再说一遍")
                return
            }
            applyVoiceText(text)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            voiceAlert = HabitVoiceAlert(kind: .error, message: "识别失败：\(detail)")
        }
    }

    /// 语音文本落库：匹配到直接打卡；匹配不到诚实提示「没找到叫 X 的习惯」。
    private func applyVoiceText(_ text: String) {
        switch store.checkInByVoice(text: text) {
        case .checked(let habitID, let name):
            let streak = store.habit(id: habitID)?.streak ?? 0
            voiceAlert = HabitVoiceAlert(
                kind: .success,
                message: streak > 0 ? "已为「\(name)」打卡，连续 \(streak) 天" : "已为「\(name)」打卡"
            )
        case .alreadyChecked(_, let name):
            voiceAlert = HabitVoiceAlert(kind: .info, message: "「\(name)」今天已经打过卡了")
        case .notFound(let name):
            voiceAlert = HabitVoiceAlert(kind: .error, message: "没找到叫「\(name)」的习惯，先点右上角「+」添加，或换个说法")
        }
    }

    /// 录音/转写结束后恢复语音唤醒监听（App 层已监听该通知，与语音日记一致）。
    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }

    // MARK: - 手动添加

    private func saveDraft() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        store.addHabit(
            name: name,
            icon: draftIcon,
            repeatDays: draftRepeat.weekdays,
            linkDailyReminder: draftLinkReminder,
            reminderTime: draftReminderTime
        )
        draftName = ""
        draftIcon = "drop.fill"
        draftRepeat = .everyDay
        draftLinkReminder = true
        draftReminderTime = HabitStore.defaultReminderTime
        showAdd = false
    }
}

// MARK: - 语音输入结果弹窗

/// 语音打卡反馈（成功/提示/失败各一条消息，诚实反馈不静默）。
struct HabitVoiceAlert: Identifiable {
    enum Kind: Equatable {
        case success
        case info
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

// MARK: - 可选图标

/// 新增习惯可选图标（SF Symbol + 中文名）。
struct HabitIconOption: Identifiable {
    let icon: String
    let label: String

    var id: String { icon }

    static let allCases: [HabitIconOption] = [
        HabitIconOption(icon: "drop.fill", label: "喝水"),
        HabitIconOption(icon: "figure.run", label: "运动"),
        HabitIconOption(icon: "moon.stars.fill", label: "早睡"),
        HabitIconOption(icon: "book.fill", label: "阅读"),
        HabitIconOption(icon: "fork.knife", label: "饮食"),
        HabitIconOption(icon: "dumbbell.fill", label: "健身"),
        HabitIconOption(icon: "heart.fill", label: "健康"),
        HabitIconOption(icon: "pencil.and.list.clipboard", label: "学习"),
        HabitIconOption(icon: "checkmark.seal.fill", label: "其他")
    ]
}

// MARK: - 编辑页

/// 习惯编辑页（行内滑动「编辑」进入）：改名/换图标/自由勾选周几/开关每日提醒。
struct HabitEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: HabitStore
    let habit: Habit

    @State private var name: String
    @State private var icon: String
    @State private var repeatDays: [Int]
    @State private var linkReminder: Bool
    @State private var reminderTime: Date

    init(habit: Habit, store: HabitStore) {
        self.habit = habit
        self.store = store
        _name = State(initialValue: habit.name)
        _icon = State(initialValue: habit.icon)
        _repeatDays = State(initialValue: habit.repeatDays)
        _linkReminder = State(initialValue: habit.linkedReminderID != nil)
        _reminderTime = State(initialValue: store.linkedReminderTime(for: habit.id) ?? HabitStore.defaultReminderTime)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("习惯") {
                    TextField("习惯名称", text: $name)
                    Picker("图标", selection: $icon) {
                        ForEach(HabitIconOption.allCases) { option in
                            Label(option.label, systemImage: option.icon).tag(option.icon)
                        }
                    }
                }

                Section("重复日") {
                    ForEach(Array(1...7), id: \.self) { weekday in
                        Toggle(Habit.weekdayName(weekday), isOn: weekdayToggle(weekday))
                    }
                }

                Section("每日提醒") {
                    Toggle("同步每日提醒", isOn: $linkReminder)
                    if linkReminder {
                        DatePicker("提醒时间", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                }
            }
            .navigationTitle("编辑习惯")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func weekdayToggle(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { repeatDays.contains(weekday) },
            set: { isOn in
                if isOn {
                    if !repeatDays.contains(weekday) { repeatDays.append(weekday) }
                } else {
                    repeatDays.removeAll { $0 == weekday }
                }
            }
        )
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = habit
        updated.name = trimmed
        updated.icon = icon
        updated.repeatDays = Array(Set(repeatDays)).sorted()
        // 空重复日兜底：默认每天
        if updated.repeatDays.isEmpty {
            updated.repeatDays = Array(1...7)
        }
        store.update(updated)
        store.setLinkedReminder(linkReminder, for: habit.id, time: reminderTime)
        dismiss()
    }
}
