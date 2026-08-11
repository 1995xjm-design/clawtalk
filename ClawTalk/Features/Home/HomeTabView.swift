import SwiftUI

/// 副主页 Tab：顶部语音助手大卡位 + 下方快捷卡片网格。
struct HomeTabView: View {
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?
    private let chatViewModel: ChatViewModel?

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 12)
    ]

    @State private var assistantViewModel: VoiceAssistantViewModel?

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil, chatViewModel: ChatViewModel? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        self.chatViewModel = chatViewModel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let assistantViewModel {
                        VoiceAssistantCardSlot(content: VoiceAssistantCardView(viewModel: assistantViewModel))
                            .padding(.horizontal, 16)
                    } else {
                        VoiceAssistantCardSlot()
                            .padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("快捷入口")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        LazyVGrid(columns: columns, spacing: 12) {
                            // 提醒卡（自带 NavigationLink → 提醒列表）
                            ReminderCardView()

                            // 健康卡（诚实占位，健康报告功能后续接入）
                            HomeCardView(
                                card: HomeCard(
                                    id: "health",
                                    title: "健康",
                                    icon: "heart.fill",
                                    color: .green,
                                    summary: "步数与健康数据",
                                    destination: HomeCardPlaceholderView(title: "健康", subtitle: "步数与健康数据")
                                )
                            )

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
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("副主页")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: configureAssistantIfNeeded)
        }
    }

    /// 语音助手接线：ChatViewModel 存在时创建会话管理器并注入 STT/TTS 服务。
    private func configureAssistantIfNeeded() {
        guard assistantViewModel == nil, let chatViewModel else { return }
        let vm = VoiceAssistantViewModel(chatViewModel: chatViewModel)
        let s = settings.settings
        vm.configure(
            transcription: AppleSTTService(language: s.whisperLanguage),
            speech: AppleTTSService(speed: s.ttsSpeed, pitch: s.ttsPitch)
        )
        assistantViewModel = vm
    }
}