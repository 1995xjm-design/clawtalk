import SwiftUI

/// 新建自动化任务（交代任务）页：
/// - 文本框/麦克风输入自然语言描述（如「每天收盘后总结股票」）
/// - 模板点选自动填名称 + cron 表达式 + 任务描述
/// - 创建前展示「计划确认」（cron 的中文描述），确认后写入本机列表并预留网关同步
struct AutomationCreateView: View {
    @Bindable var viewModel: AutomationViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var taskName = ""
    @State private var cronExpression = ""
    @State private var taskDescription = ""
    @State private var selectedTemplateID: String?
    @State private var parseError: String?
    @State private var isRecording = false
    @State private var isTranscribing = false

    @State private var voiceInput = VoiceInputStateMachine()
    private let transcriptionService: (any TranscriptionService)?

    init(viewModel: AutomationViewModel, transcription: (any TranscriptionService)? = nil) {
        self.viewModel = viewModel
        self.transcriptionService = transcription
    }

    var body: some View {
        Form {
            promptSection
            templateSection
            confirmationSection
            createSection
        }
        .navigationTitle("新建自动化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("取消") {
                    dismiss()
                }
            }
        }
    }

    // MARK: - 交代任务

    @ViewBuilder
    private var promptSection: some View {
        Section {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("例：每天收盘后总结股票", text: $prompt, axis: .vertical)
                    .lineLimit(3...5)

                Button {
                    Task { await toggleRecording() }
                } label: {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.title2)
                        .foregroundStyle(isRecording ? .red : Color.openClawRed)
                }
                .buttonStyle(.plain)
                .disabled(isTranscribing)
                .accessibilityLabel(isRecording ? "停止录音" : "语音交代任务")
            }

            if isRecording {
                Label("正在录音…说完自动识别", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isTranscribing {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在识别…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("交代任务")
        } footer: {
            Text("用一句话说明做什么、什么时候做。支持「每天早上」「每周五下午」「每工作日」「每天收盘后」等说法；识别不了的时间建议用模板。")
        }
    }

    // MARK: - 模板

    @ViewBuilder
    private var templateSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(AutomationTemplate.all) { template in
                        templateChip(template)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("模板")
        } footer: {
            Text("点选模板自动填写名称、cron 表达式与任务描述，可再修改。")
        }
    }

    private func templateChip(_ template: AutomationTemplate) -> some View {
        let isSelected = selectedTemplateID == template.id
        return Button {
            select(template)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: template.systemImage)
                    .font(.title3)
                Text(template.title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(width: 88, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.openClawRed.opacity(0.12) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.openClawRed : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private func select(_ template: AutomationTemplate) {
        selectedTemplateID = template.id
        parseError = nil
        taskName = template.name
        cronExpression = template.cronExpression
        taskDescription = template.taskDescription
        if prompt.isEmpty {
            prompt = template.samplePrompt
        }
    }

    // MARK: - 计划确认

    @ViewBuilder
    private var confirmationSection: some View {
        Section {
            if !cronExpression.isEmpty {
                TextField("任务名称", text: $taskName)

                LabeledContent("计划") {
                    Text(CronParser.describe(cron: cronExpression) ?? cronExpression)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("cron") {
                    Text(cronExpression)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                if !taskDescription.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("任务内容")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(taskDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !prompt.isEmpty {
                Button("从描述解析时间") {
                    parsePrompt()
                }
            }

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("计划确认")
        } footer: {
            Text("创建前请确认计划与内容；下次执行时间由网关排程后回填。")
        }
    }

    // MARK: - 创建

    @ViewBuilder
    private var createSection: some View {
        Section {
            Button {
                createTask()
            } label: {
                Text("创建任务")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(cronExpression.isEmpty)
        } footer: {
            Text("任务先保存在本机；网关 cron 接口确认后会自动同步执行，结果推送到手机。")
        }
    }

    // MARK: - 行为

    private func parsePrompt() {
        parseError = nil
        guard let cron = CronParser.cron(from: prompt) else {
            parseError = "没听懂这个时间说法。试试上面的模板，或填写 5 段 cron（分 时 日 月 周）。"
            return
        }
        cronExpression = cron
        selectedTemplateID = nil
        if taskName.isEmpty {
            taskName = deriveName(from: prompt)
        }
    }

    private func createTask() {
        parseError = nil
        var cron = cronExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        if cron.isEmpty {
            cron = CronParser.cron(from: prompt) ?? ""
        }
        guard !cron.isEmpty else {
            parseError = "还没有可用的计划：点「从描述解析时间」或选一个模板。"
            return
        }
        let trimmedName = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? deriveName(from: prompt) : trimmedName
        let task = AutomationTask(
            name: finalName,
            cronExpression: cron,
            description: taskDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: true
        )
        viewModel.addTask(task)
        dismiss()
    }

    private func deriveName(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "自动化任务" }
        return String(trimmed.prefix(12))
    }

    // MARK: - 麦克风

    @MainActor
    private func toggleRecording() async {
        if isRecording {
            isRecording = false
            // 统一走语音输入状态机：误触/空样本由状态机判弃并恢复会话
            guard let capture = voiceInput.finishShortCapture(), !capture.samples.isEmpty else { return }
            isTranscribing = true
            defer {
                isTranscribing = false
                voiceInput.endSession()
            }
            do {
                let service = transcriptionService ?? AppleSTTService(language: "zh-CN")
                let text = try await service.transcribe(audioSamples: capture.samples)
                if prompt.isEmpty {
                    prompt = text
                } else {
                    prompt += text
                }
                parsePrompt()
            } catch {
                parseError = "语音识别失败：\(AppErrorText.localized(error.localizedDescription))"
            }
        } else {
            parseError = nil
            voiceInput.startShort()
            if voiceInput.isCapturing {
                isRecording = true
            } else if let error = voiceInput.errorMessage {
                parseError = error
            }
        }
    }
}

// MARK: - 模板

/// 自动化任务模板：点选自动填名称 / cron / 描述
struct AutomationTemplate: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let name: String
    let cronExpression: String
    let taskDescription: String
    let samplePrompt: String

    static let all: [AutomationTemplate] = [
        AutomationTemplate(
            id: "daily_brief",
            title: "每日简报",
            systemImage: "sun.max",
            name: "每日简报",
            cronExpression: "0 8 * * *",
            taskDescription: "每天早上给我一份当日简报：天气、日程、待办和重要新闻。",
            samplePrompt: "每天早上8点给我发每日简报"
        ),
        AutomationTemplate(
            id: "daily_stock",
            title: "每日收盘总结",
            systemImage: "chart.line.uptrend.xyaxis",
            name: "每日收盘总结",
            cronExpression: "0 15 * * 1-5",
            taskDescription: "每个交易日收盘后总结 A 股市场行情：指数涨跌、板块热点、值得关注的公司。",
            samplePrompt: "每天收盘后总结股票"
        ),
        AutomationTemplate(
            id: "weekly_health",
            title: "每周健康报告",
            systemImage: "heart",
            name: "每周健康报告",
            cronExpression: "0 9 * * 1",
            taskDescription: "每周一早上整理本周健康数据：睡眠、步数、运动时长，并给出建议。",
            samplePrompt: "每周一早上9点给我每周健康报告"
        ),
        AutomationTemplate(
            id: "custom",
            title: "自定义",
            systemImage: "slider.horizontal.3",
            name: "",
            cronExpression: "",
            taskDescription: "",
            samplePrompt: ""
        )
    ]
}
