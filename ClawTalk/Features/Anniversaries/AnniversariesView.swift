import SwiftUI

/// 纪念日列表页：按「下一个纪念日」排序，每条显示名称 / 日期 / 剩余天数徽章 /
/// 提前提醒设置；顶部「按住说话新建纪念日」（统一语音输入状态机 + AppleSTTService
/// + AnniversaryVoiceParser）：说「5月20号是结婚纪念日」自动解析日期+名称+类型创建，
/// 解析不出日期弹表单手动填（名称预填）；右上角「+」手动添加；空列表诚实空状态。
struct AnniversariesView: View {
    @State private var store: AnniversaryStore
    @State private var showAddForm = false
    @State private var editingAnniversary: Anniversary?

    // 语音输入（复用统一语音输入状态机；STT 保持本页 Apple 服务）
    @State private var voiceInput = VoiceInputStateMachine()
    @State private var stt: any TranscriptionService = AppleSTTService()
    @State private var isVoiceRecording = false
    @State private var isTranscribing = false
    @State private var voiceAlert: AnniversaryVoiceAlert?

    // 新增/编辑表单草稿
    @State private var draftName = ""
    @State private var draftDate = Date()
    @State private var draftType: AnniversaryType = .anniversary
    @State private var draftRepeatsYearly = true
    @State private var draftRemindBefore: Set<Int> = [1]
    @State private var draftNote = ""

    init(store: AnniversaryStore? = nil, autoOpenAdd: Bool = false) {
        _store = State(initialValue: store ?? AnniversaryStore())
        _showAddForm = State(initialValue: autoOpenAdd)
    }

    var body: some View {
        List {
            Section {
                GlobalVoiceInputEmbedded(settingsStore: SettingsStore()) { text, _ in
                    applyVoiceText(text)
                }
            } header: {
                Text("语音添加纪念日")
            }

            if store.anniversaries.isEmpty {
                ContentUnavailableView {
                    Label("暂无纪念日", systemImage: "calendar.badge.clock")
                } description: {
                    Text("按住上方按钮说「5月20号是结婚纪念日」，\n或点右上角「+」手动添加。数据只保存在本机。")
                } actions: {
                    Button("添加纪念日") {
                        beginAddForm(name: "")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(store.anniversaries) { anniversary in
                anniversaryRow(anniversary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.delete(id: anniversary.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("纪念日")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    beginAddForm(name: "")
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.openClawRed)
                }
                .accessibilityLabel("添加纪念日")

            }
        }
        .sheet(isPresented: $showAddForm) {
            NavigationStack {
                AnniversaryFormView(
                    title: editingAnniversary == nil ? "新建纪念日" : "编辑纪念日",
                    name: $draftName,
                    date: $draftDate,
                    type: $draftType,
                    repeatsYearly: $draftRepeatsYearly,
                    remindBefore: $draftRemindBefore,
                    note: $draftNote,
                    onSave: saveDraft,
                    onCancel: {
                        showAddForm = false
                        editingAnniversary = nil
                    }
                )
            }
            .presentationDetents([.medium, .large])
        }
        .alert(item: $voiceAlert) { alert in
            Alert(
                title: Text(alert.kind == .success ? "已添加纪念日" : "语音新建"),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .safeAreaInset(edge: .bottom) {
            if store.notificationPermissionDenied {
                Text("通知权限被关闭，纪念日不会提醒。请在系统设置里允许通知。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    // MARK: - 行

    private func anniversaryRow(_ anniversary: Anniversary) -> some View {
        Button {
            beginEditForm(anniversary)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(anniversary.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        AnniversaryTypeBadge(type: anniversary.type)
                    }
                    Text(dateSubtitle(anniversary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !anniversary.remindDaysBefore.isEmpty {
                        Text(remindText(anniversary))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let note = anniversary.note, !note.isEmpty {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                countdownBadge(anniversary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func countdownBadge(_ anniversary: Anniversary) -> some View {
        if let days = store.daysUntilNext(for: anniversary) {
            Text(days == 0 ? "今天" : days == 1 ? "明天" : "还有 \(days) 天")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(days == 0 ? Color.openClawRed : Color.pink, in: Capsule())
        } else {
            Text("已过")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }

    private func dateSubtitle(_ anniversary: Anniversary) -> String {
        if anniversary.repeatsYearly {
            return "每年 \(monthDayText(anniversary.date))"
        }
        return yearText(anniversary.date)
    }

    private func remindText(_ anniversary: Anniversary) -> String {
        let days = anniversary.remindDaysBefore.sorted()
        guard !days.isEmpty else { return "不提醒" }
        let labels = days.map { $0 == 0 ? "当天" : "提前 \($0) 天" }
        return labels.joined(separator: "、") + "提醒"
    }

    private func monthDayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func yearText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: date)
    }

    // MARK: - 表单

    private func beginAddForm(name: String) {
        editingAnniversary = nil
        draftName = name
        draftDate = Date()
        draftType = .anniversary
        draftRepeatsYearly = true
        draftRemindBefore = [1]
        draftNote = ""
        showAddForm = true
    }

    private func beginEditForm(_ anniversary: Anniversary) {
        editingAnniversary = anniversary
        draftName = anniversary.name
        draftDate = anniversary.date
        draftType = anniversary.type
        draftRepeatsYearly = anniversary.repeatsYearly
        draftRemindBefore = Set(anniversary.remindDaysBefore)
        draftNote = anniversary.note ?? ""
        showAddForm = true
    }

    private func saveDraft() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let note = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let remindDays = draftRemindBefore.sorted()

        if var anniversary = editingAnniversary {
            anniversary.name = name
            anniversary.date = draftDate
            anniversary.type = draftType
            anniversary.repeatsYearly = draftRepeatsYearly
            anniversary.remindDaysBefore = remindDays
            anniversary.note = note.isEmpty ? nil : note
            store.update(anniversary)
        } else {
            store.add(
                Anniversary(
                    name: name,
                    date: draftDate,
                    type: draftType,
                    repeatsYearly: draftRepeatsYearly,
                    remindDaysBefore: remindDays,
                    note: note.isEmpty ? nil : note
                )
            )
        }
        showAddForm = false
        editingAnniversary = nil
    }

    // MARK: - 按住说话新建纪念日

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
                    Text(isVoiceRecording ? "说完松手，自动识别成纪念日" : "例如「5月20号是结婚纪念日」")
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
        return "按住说话新建纪念日"
    }

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isVoiceRecording, !isTranscribing else { return }
                // 统一走语音输入状态机（录音前状态机会先停语音唤醒，避免两个音频引擎抢麦）
                voiceInput.startShort()
                if voiceInput.isCapturing {
                    isVoiceRecording = true
                } else if let error = voiceInput.errorMessage {
                    voiceAlert = AnniversaryVoiceAlert(kind: .error, message: error)
                }
            }
            .onEnded { _ in
                guard isVoiceRecording else { return }
                isVoiceRecording = false
                guard let capture = voiceInput.finishShortCapture() else {
                    // 误触/过短：状态机已恢复会话，保留原「录音太短」提示
                    voiceAlert = AnniversaryVoiceAlert(kind: .error, message: "录音太短，请按住说完整一句话")
                    return
                }
                Task { await processRecordedSamples(capture.samples) }
            }
    }

    @MainActor
    private func processRecordedSamples(_ samples: [Float]) async {
        // 误触阈值由状态机判定（约 0.5s / 8000 样本 @16kHz），此处直接转写
        isTranscribing = true
        defer {
            isTranscribing = false
            voiceInput.endSession()
        }

        do {
            let transcript = try await stt.transcribe(audioSamples: samples)
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                voiceAlert = AnniversaryVoiceAlert(kind: .error, message: "没有识别到内容，请再说一遍")
                return
            }
            applyVoiceText(text)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            voiceAlert = AnniversaryVoiceAlert(kind: .error, message: "识别失败：\(detail)")
        }
    }

    /// 语音文本落库：能解析出日期直接创建；解析不出弹手动填写（名称预填）。
    private func applyVoiceText(_ text: String) {
        switch AnniversaryVoiceParser.parse(text) {
        case .success(let draft):
            store.add(
                Anniversary(
                    name: draft.name,
                    date: draft.date,
                    type: draft.type,
                    repeatsYearly: draft.repeatsYearly,
                    remindDaysBefore: [1],
                    note: nil
                )
            )
            voiceAlert = AnniversaryVoiceAlert(
                kind: .success,
                message: "「\(draft.name)」已添加（\(monthDayText(draft.date))）"
            )
        case .failure:
            beginAddForm(name: AnniversaryVoiceParser.extractNameOnly(from: text))
        }
    }

}

// MARK: - 类型徽章

/// 纪念日类型徽章：类型名 + 图标 + 主题色胶囊背景（与提醒类别徽章同款）。
struct AnniversaryTypeBadge: View {
    let type: AnniversaryType

    var body: some View {
        Label(type.rawValue, systemImage: type.iconName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(type.themeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(type.themeColor.opacity(0.14), in: Capsule())
    }
}

extension AnniversaryType {
    /// 类型图标（SF Symbols）
    var iconName: String {
        switch self {
        case .birthday: return "birthday.cake.fill"
        case .anniversary: return "heart.fill"
        case .holiday: return "party.popper.fill"
        case .custom: return "star.fill"
        }
    }

    /// 类型主题色（浅色/深色下均有对比度）
    var themeColor: Color {
        switch self {
        case .birthday: return .pink
        case .anniversary: return .red
        case .holiday: return .orange
        case .custom: return .purple
        }
    }
}

// MARK: - 语音输入结果弹窗

/// 语音输入反馈（成功/失败各一条消息，诚实反馈不静默）。
struct AnniversaryVoiceAlert: Identifiable {
    enum Kind: Equatable {
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

// MARK: - 新增/编辑表单

/// 纪念日表单：名称 / 日期 / 类型 / 每年重复开关 / 提前提醒天数（可多选）/ 备注。
private struct AnniversaryFormView: View {
    let title: String
    @Binding var name: String
    @Binding var date: Date
    @Binding var type: AnniversaryType
    @Binding var repeatsYearly: Bool
    @Binding var remindBefore: Set<Int>
    @Binding var note: String
    let onSave: () -> Void
    let onCancel: () -> Void

    /// 提前提醒可选档位：当天 / 提前1天 / 提前3天 / 提前7天。
    private let remindOptions: [RemindOption] = [
        RemindOption(days: 0, label: "当天"),
        RemindOption(days: 1, label: "提前 1 天"),
        RemindOption(days: 3, label: "提前 3 天"),
        RemindOption(days: 7, label: "提前 7 天")
    ]

    var body: some View {
        Form {
            Section("名称") {
                TextField("例如：结婚纪念日 / 妈妈生日", text: $name)
            }

            Section("日期") {
                DatePicker("日期", selection: $date, displayedComponents: .date)
            }

            Section("类型") {
                Picker("类型", selection: $type) {
                    ForEach(AnniversaryType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
            }

            Section {
                Toggle("每年重复", isOn: $repeatsYearly)
            } footer: {
                Text("生日/纪念日/节日默认每年重复；关闭后为一次性纪念日，到点提醒一次。农历节日（春节/中秋等）每年公历日期不同，请每年手动调整日期。")
            }

            Section("提前提醒") {
                ForEach(remindOptions) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { remindBefore.contains(option.days) },
                        set: { isOn in
                            if isOn {
                                remindBefore.insert(option.days)
                            } else {
                                remindBefore.remove(option.days)
                            }
                        }
                    ))
                }
            }

            Section("备注") {
                TextField("备注（可选）", text: $note)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    onCancel()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

/// 提前提醒档位（多选列表用）。
private struct RemindOption: Identifiable {
    let days: Int
    let label: String

    var id: Int { days }
}