import Foundation
import SwiftUI

/// 语音记账录音状态。
enum ExpenseRecordingState: Equatable {
    case idle
    case recording
    case transcribing
}

/// 录音 → STT → 解析 控制器（与 VoiceDiaryViewModel 同款流程）：
/// 按住说话（AudioCaptureManager）→ 松开后 STT 转写（按 SettingsStore.sttProvider 选服务）
/// → ExpenseVoiceParser 本地规则解析。解析成功把草稿交给页面确认保存；
/// 解析不出金额回调 .needsManual，由页面弹 alert 引导手动填写（诚实，不做假解析）。
/// 错误统一写 errorMessage（页面内联展示），不进 onOutcome。
@MainActor
@Observable
final class ExpenseRecordingController {

    /// 一次录音的最终结果，交给页面决定 UI。
    enum Outcome: Equatable {
        /// 解析成功（尚未保存，由页面确认后写入 ExpenseStore）
        case parsed(ExpenseVoiceParser.Draft)
        /// 没解析出金额（诚实，弹 alert 手动填），附转写原文
        case needsManual(String)
    }

    private let settingsStore: SettingsStore
    private let audioCapture = AudioCaptureManager()
    /// 按 SettingsStore.sttProvider 懒创建，规则与 ClawTalkApp.configureServices 一致
    private var transcriptionService: (any TranscriptionService)?
    private var levelTimer: Timer?
    private var recordingStart: Date?

    private(set) var state: ExpenseRecordingState = .idle
    /// 录音实时电平（驱动录音中的脉冲动画）
    var audioLevel: Float = 0
    var errorMessage: String?
    /// 每次录音完成回调（主线程）；解析成功/需要手动填都会触发
    var onOutcome: ((Outcome) -> Void)?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    // MARK: - 录音

    /// 开始录音（按住说话达到阈值时调用）。与聊天页一致：先停语音唤醒，避免两个音频引擎抢麦。
    func startRecording() {
        guard state == .idle else { return }
        VoiceWakeCapability.shared.stopListening()
        errorMessage = nil
        do {
            try audioCapture.startRecording()
            recordingStart = Date()
            state = .recording
            startLevelTimer()
        } catch {
            errorMessage = "麦克风访问失败：\(AppErrorText.localized(error.localizedDescription))"
            restoreWakeListening()
        }
    }

    /// 结束录音并转写（松开时调用）。过短的误触录音直接丢弃。
    func stopRecordingAndProcess() {
        guard state == .recording else { return }
        stopLevelTimer()
        let samples = audioCapture.stopRecording()

        // 与聊天页同阈值：<0.5s 或样本过少视为误触
        let duration = Date().timeIntervalSince(recordingStart ?? Date())
        guard duration >= 0.5, samples.count > 8000 else {
            state = .idle
            restoreWakeListening()
            return
        }

        state = .transcribing
        Task {
            defer { restoreWakeListening() }
            guard let stt = makeTranscriptionService() else {
                errorMessage = "语音输入已在设置中关闭，请到设置页开启后重试"
                state = .idle
                return
            }
            do {
                let transcript = try await stt.transcribe(audioSamples: samples)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "没有识别到内容，请再试一次"
                    state = .idle
                    return
                }
                if let draft = ExpenseVoiceParser.parse(trimmed) {
                    onOutcome?(.parsed(draft))
                } else {
                    onOutcome?(.needsManual(trimmed))
                }
                state = .idle
            } catch {
                errorMessage = "转写失败：\(AppErrorText.localized(error.localizedDescription))"
                state = .idle
            }
        }
    }

    /// 页面退出时丢弃未完成的录音（不转写、不保存）。
    func discardActiveRecording() {
        guard state == .recording else { return }
        stopLevelTimer()
        _ = audioCapture.stopRecording()
        state = .idle
        restoreWakeListening()
    }

    /// 设置里切换 STT 提供商后由外部调用，重建服务。
    func rebuildSTTService() {
        transcriptionService = nil
    }

    // MARK: - STT 服务工厂

    /// 按 SettingsStore.sttProvider 创建 STT 服务（与 VoiceDiaryViewModel 同规则）：
    /// - .apple → AppleSTTService(language: whisperLanguage)
    /// - .doubao → 有豆包 API Key 用 DoubaoSTTService，否则回退 Apple
    /// - voiceInputEnabled 关闭 → 返回 nil（页面提示去设置开启）
    private func makeTranscriptionService() -> (any TranscriptionService)? {
        let settings = settingsStore.settings
        guard settings.voiceInputEnabled else { return nil }
        if let cached = transcriptionService { return cached }

        let service: any TranscriptionService
        switch settings.sttProvider {
        case .apple:
            service = AppleSTTService(language: settings.whisperLanguage)
        case .doubao:
            if let key = SecureStorage.shared.doubaoAPIKey, !key.isEmpty {
                service = DoubaoSTTService(apiKey: key, language: settings.whisperLanguage)
            } else {
                service = AppleSTTService(language: settings.whisperLanguage)
            }
        }
        transcriptionService = service
        return service
    }

    // MARK: - 录音电平轮询（驱动录音中脉冲动画）

    private func startLevelTimer() {
        stopLevelTimer()
        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.audioLevel = self.audioCapture.currentLevel
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        levelTimer = timer
    }

    private func stopLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
    }

    /// 录音/转写结束后恢复语音唤醒监听（App 层已监听该通知）。
    private func restoreWakeListening() {
        NotificationCenter.default.post(name: .clawTalkWakeRestartRequested, object: nil)
    }
}

/// 语音记账页：月度汇总卡 + 顶部「按住说话记账」+ 手动添加 + 按日期分组的账目列表。
/// - 按住顶部按钮说话，松开后自动转写 → 本地规则解析 → 确认后保存
/// - 解析不出金额弹 alert 手动填（金额必填，诚实空状态）
struct ExpenseListView: View {
    @State private var store: ExpenseStore
    @State private var recording: ExpenseRecordingController
    /// 关闭/返回回调（由入口通过 sheet / NavigationStack 传入）
    var onBack: (() -> Void)?

    // 按住说话手势状态（参考 VoiceDiaryView）
    @State private var isPressed = false
    @State private var holdTimer: Task<Void, Never>?
    @State private var isHolding = false
    @State private var showHoldHint = false

    // 解析成功确认 alert
    @State private var confirmItem: ExpenseConfirmItem?
    // 解析失败 alert → 手动填写
    @State private var showParseFailAlert = false
    @State private var parseFailTranscript = ""

    // 手动填写 sheet
    @State private var showManualSheet = false
    @State private var manualAmountText = ""
    @State private var manualType: ExpenseType = .expense
    @State private var manualCategory: ExpenseCategory = .other
    @State private var manualNote = ""
    @State private var manualError: String?

    private let hapticsEnabled: Bool
    /// 按住多久算开始录音（0.3 秒，与 TalkButton 一致）
    private let holdThreshold: UInt64 = 300_000_000

    init(
        settingsStore: SettingsStore,
        store: ExpenseStore? = nil,
        onBack: (() -> Void)? = nil
    ) {
        let resolvedStore = store ?? ExpenseStore()
        _store = State(initialValue: resolvedStore)
        _recording = State(initialValue: ExpenseRecordingController(settingsStore: settingsStore))
        self.onBack = onBack
        self.hapticsEnabled = settingsStore.settings.hapticsEnabled
    }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            actionArea
                .padding(.horizontal, 16)
                .padding(.top, 12)
            Divider().opacity(0.3)
                .padding(.top, 12)

            summaryCard
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if store.entries.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                entryList
            }
        }
        .background(Color(.systemBackground))
        .onAppear {
            store.reload()
            recording.onOutcome = { outcome in
                handleOutcome(outcome)
            }
        }
        .onDisappear { recording.discardActiveRecording() }
        .alert(item: $confirmItem) { item in
            Alert(
                title: Text("已记一笔"),
                message: Text("\(item.draft.type.rawValue) ¥\(item.draft.amount.expenseAmountText) · \(item.draft.category.rawValue)\n「\(item.draft.note)」"),
                primaryButton: .default(Text("好")) {
                    saveDraft(item.draft)
                },
                secondaryButton: .cancel(Text("记错了")) {
                    presentManualEdit(from: item.draft)
                }
            )
        }
        .sheet(isPresented: $showManualSheet) {
            manualSheet
        }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            Text("语音记账")
                .font(.headline)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Color(.systemGray5), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
    }

    // MARK: - 顶部操作区（按住说话记账 + 手动添加）

    private var actionArea: some View {
        VStack(spacing: 10) {
            recordCapsule
                .alert("没听清金额", isPresented: $showParseFailAlert) {
                    Button("手动填写") {
                        presentManualEdit(transcript: parseFailTranscript)
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("这句话里没找到金额，请手动填写金额和类别。")
                }

            Button(action: presentManualAdd) {
                Label("手动添加", systemImage: "plus")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
            }
            .buttonStyle(.plain)

            if let errorMessage = recording.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 「按住说话记账」胶囊按钮（录音中显示脉冲 + 状态文案）
    private var recordCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .symbolEffect(.pulse, isActive: recording.state == .recording)
            Text(recordLabel)
                .font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Capsule().fill(recordColor))
        .contentShape(Capsule())
        .gesture(recordGesture)
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.65), value: isPressed)
        .disabled(recording.state == .transcribing)
        .accessibilityLabel(recordAccessibilityLabel)
    }

    private var recordLabel: String {
        switch recording.state {
        case .idle: return showHoldHint ? "按住说话，松开结束" : "按住说话记账"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "识别中…"
        }
    }

    private var recordColor: Color {
        switch recording.state {
        case .idle: return .openClawRed
        case .recording: return .red
        case .transcribing: return .openClawRed.opacity(0.5)
        }
    }

    private var recordAccessibilityLabel: String {
        switch recording.state {
        case .idle: return "按住说话记账，松开自动识别金额"
        case .recording: return "正在录音，松开结束"
        case .transcribing: return "正在识别转写结果"
        }
    }

    private var canInteract: Bool {
        recording.state == .idle || recording.state == .recording
    }

    // MARK: - 按住说话手势（参考 VoiceDiaryView）

    private var recordGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !isPressed, canInteract else { return }
                isPressed = true
                isHolding = false
                if recording.state == .recording {
                    // 录音中再次按下：仅标记按压，松开即停止
                    return
                }
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                holdTimer = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: holdThreshold)
                    guard !Task.isCancelled else { return }
                    isHolding = true
                    if hapticsEnabled {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    }
                    recording.startRecording()
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                guard isPressed else { return }
                isPressed = false
                if hapticsEnabled {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                if recording.state == .recording || isHolding {
                    recording.stopRecordingAndProcess()
                } else {
                    // 短按未开始录音：提示按住说话
                    showHoldHint = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        showHoldHint = false
                    }
                }
            }
    }

    // MARK: - 月度汇总卡

    private var summaryCard: some View {
        let summary = store.monthSummary()
        return HStack(spacing: 0) {
            summaryStat(title: "本月支出", amount: summary.expense, color: .orange, icon: "arrow.up.right")
            Divider().frame(height: 34)
            summaryStat(title: "本月收入", amount: summary.income, color: .green, icon: "arrow.down.left")
            Divider().frame(height: 34)
            summaryStat(title: "结余", amount: summary.balance, color: summary.balance >= 0 ? .blue : .red, icon: "equal")
        }
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private func summaryStat(title: String, amount: Double, color: Color, icon: String) -> some View {
        VStack(spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text("¥\(amount.expenseAmountText)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 列表（按日期分组）

    private var entryList: some View {
        let grouped = Dictionary(grouping: store.entries) {
            Calendar.current.startOfDay(for: $0.date)
        }
        let dayKeys = grouped.keys.sorted(by: >)

        return List {
            ForEach(dayKeys, id: \.self) { day in
                let dayEntries = (grouped[day] ?? []).sorted { $0.createdAt > $1.createdAt }
                Section(header: Text(Self.dayHeader(for: day))) {
                    ForEach(dayEntries) { entry in
                        ExpenseEntryRow(entry: entry)
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            store.delete(dayEntries[offset].id)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 日期分组标题：今天 / 昨天 / M月d日 星期X
    private static func dayHeader(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 EEEE"
        return formatter.string(from: day)
    }

    // MARK: - 空状态（诚实，不塞假数据）

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "yensign.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有记账")
                .font(.headline)
            Text("按住上方「按住说话记账」说一句，比如「买咖啡花了28」或「收到工资8000」，会自动记一笔；也可以点「手动添加」自己填。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    // MARK: - 录音结果处理

    private func handleOutcome(_ outcome: ExpenseRecordingController.Outcome) {
        switch outcome {
        case .parsed(let draft):
            confirmItem = ExpenseConfirmItem(draft: draft)
        case .needsManual(let transcript):
            parseFailTranscript = transcript
            showParseFailAlert = true
        }
    }

    private func saveDraft(_ draft: ExpenseVoiceParser.Draft) {
        store.add(
            amount: draft.amount,
            type: draft.type,
            category: draft.category,
            note: draft.note
        )
    }

    // MARK: - 手动填写

    private func presentManualAdd() {
        manualAmountText = ""
        manualType = .expense
        manualCategory = .other
        manualNote = ""
        manualError = nil
        showManualSheet = true
    }

    /// 解析成功但用户点「记错了」：带入已解析的值修改
    private func presentManualEdit(from draft: ExpenseVoiceParser.Draft) {
        manualAmountText = draft.amount.expenseAmountText
        manualType = draft.type
        manualCategory = draft.category
        manualNote = draft.note
        manualError = nil
        showManualSheet = true
    }

    /// 解析失败：原话带入备注，金额留空手动填
    private func presentManualEdit(transcript: String) {
        manualAmountText = ""
        manualType = .expense
        manualCategory = .other
        manualNote = transcript
        manualError = nil
        showManualSheet = true
    }

    private var manualSheet: some View {
        NavigationStack {
            Form {
                Section("金额（必填）") {
                    TextField("例如 28.5", text: $manualAmountText)
                        .keyboardType(.decimalPad)
                    if let manualError {
                        Text(manualError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section("类型") {
                    Picker("类型", selection: $manualType) {
                        ForEach(ExpenseType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("类别") {
                    Picker("类别", selection: $manualCategory) {
                        ForEach(ExpenseCategory.allCases, id: \.self) { category in
                            Label(category.rawValue, systemImage: category.iconName).tag(category)
                        }
                    }
                }
                Section("备注") {
                    TextField("备注（可选）", text: $manualNote)
                }
            }
            .navigationTitle("手动记账")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showManualSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveManualEntry() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func saveManualEntry() {
        let trimmed = manualAmountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = Double(trimmed), amount > 0 else {
            manualError = "请填写正确的金额（大于 0）"
            return
        }
        let note = manualNote.trimmingCharacters(in: .whitespacesAndNewlines)
        store.add(amount: amount, type: manualType, category: manualCategory, note: note)
        showManualSheet = false
        manualAmountText = ""
        manualNote = ""
        manualError = nil
    }
}

/// 解析成功确认 alert 的携带项（Identifiable 供 .alert(item:) 使用）。
private struct ExpenseConfirmItem: Identifiable {
    let id = UUID()
    let draft: ExpenseVoiceParser.Draft
}

/// 账目列表行：类别图标 + 类别/备注 + 时间 + 带符号金额。
private struct ExpenseEntryRow: View {
    let entry: ExpenseEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.category.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(entry.category.themeColor)
                .frame(width: 34, height: 34)
                .background(
                    entry.category.themeColor.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.category.rawValue)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Text(Self.timeText(entry.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Text(signText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(entry.type == .income ? Color.green : Color.primary)
        }
        .padding(.vertical, 2)
    }

    private var signText: String {
        let sign = entry.type == .income ? "+" : "-"
        return "\(sign)¥\(entry.amount.expenseAmountText)"
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}