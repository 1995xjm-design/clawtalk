import SwiftUI

/// 副主页五张占位卡片数据源：提醒 / 健康 / 语音日记 / 我的记忆 / 自动化。
/// 目标页统一为「引导页」（HomeCardPlaceholderView）：图标 + 标题 + 第一次怎么用，
/// 诚实空状态；对应功能组就绪后由主智能体替换 destination。
struct ReminderCardsPlaceholder {
    static let cards: [HomeCard<HomeCardPlaceholderView>] = [
        HomeCard(
            id: "reminders",
            title: "提醒",
            icon: "bell.badge.fill",
            color: .orange,
            summary: "待办与定时提醒",
            destination: HomeCardPlaceholderView(
                title: "提醒",
                subtitle: "待办与定时提醒",
                icon: "bell.badge.fill",
                color: .orange,
                guide: "在语音助手或提醒卡片里说「提醒我下午三点开会」，ClawTalk 会自动创建提醒并到点通知你。"
            )
        ),
        HomeCard(
            id: "health",
            title: "健康",
            icon: "heart.fill",
            color: .green,
            summary: "步数与健康数据",
            destination: HomeCardPlaceholderView(
                title: "健康",
                subtitle: "步数与健康数据",
                icon: "heart.fill",
                color: .green,
                guide: "在系统设置里允许 ClawTalk 访问健康数据后，这里会自动显示步数与近 7 天趋势。"
            )
        ),
        HomeCard(
            id: "voice-diary",
            title: "语音日记",
            icon: "waveform",
            color: .pink,
            summary: "说一段话，记下今天",
            destination: HomeCardPlaceholderView(
                title: "语音日记",
                subtitle: "说一段话，记下今天",
                icon: "waveform",
                color: .pink,
                guide: "按住录音键说一段话，松开后自动转成文字，并归类为日记 / 待办 / 灵感。"
            )
        ),
        HomeCard(
            id: "my-memory",
            title: "我的记忆",
            icon: "brain.head.profile",
            color: .purple,
            summary: "第二大脑 · 检索记忆",
            destination: HomeCardPlaceholderView(
                title: "我的记忆",
                subtitle: "第二大脑 · 检索记忆",
                icon: "brain.head.profile",
                color: .purple,
                guide: "把重要的对话、灵感告诉语音助手，沉淀后在这里检索，像第二大脑一样随时调用。"
            )
        ),
        HomeCard(
            id: "automation",
            title: "自动化",
            icon: "bolt.fill",
            color: .blue,
            summary: "自动流程与快捷指令",
            destination: HomeCardPlaceholderView(
                title: "自动化",
                subtitle: "自动流程与快捷指令",
                icon: "bolt.fill",
                color: .blue,
                guide: "说一句「每天收盘后总结股票」，到点自动运行并把结果推送到手机。"
            )
        )
    ]
}

/// 占位目标页（引导页）：图标 + 标题 + 「第一次怎么用」文案。
/// 诚实空状态：功能未就绪时不展示假数据，只说明功能与用法，等对应功能组替换目标页。
struct HomeCardPlaceholderView: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let guide: String

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(color)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    Text(title)
                        .font(.system(.title3, weight: .bold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Divider()
                        .padding(.vertical, 4)

                    Label("第一次怎么用", systemImage: "questionmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(guide)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .padding(.horizontal, 16)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
