import SwiftUI

/// 副主页五张占位卡片数据源：提醒 / 健康 / 语音日记 / 我的记忆 / 自动化。
/// 目标页先接统一占位页（诚实空状态），后续由各功能组替换 destination。
struct ReminderCardsPlaceholder {
    static let cards: [HomeCard<HomeCardPlaceholderView>] = [
        HomeCard(
            id: "reminders",
            title: "提醒",
            icon: "bell.badge.fill",
            color: .orange,
            summary: "待办与定时提醒",
            destination: HomeCardPlaceholderView(title: "提醒", subtitle: "待办与定时提醒")
        ),
        HomeCard(
            id: "health",
            title: "健康",
            icon: "heart.fill",
            color: .green,
            summary: "步数与健康数据",
            destination: HomeCardPlaceholderView(title: "健康", subtitle: "步数与健康数据")
        ),
        HomeCard(
            id: "voice-diary",
            title: "语音日记",
            icon: "waveform",
            color: .pink,
            summary: "说一段话，记下今天",
            destination: HomeCardPlaceholderView(title: "语音日记", subtitle: "说一段话，记下今天")
        ),
        HomeCard(
            id: "my-memory",
            title: "我的记忆",
            icon: "brain.head.profile",
            color: .purple,
            summary: "第二大脑 · 检索记忆",
            destination: HomeCardPlaceholderView(title: "我的记忆", subtitle: "第二大脑 · 检索记忆")
        ),
        HomeCard(
            id: "automation",
            title: "自动化",
            icon: "bolt.fill",
            color: .blue,
            summary: "自动流程与快捷指令",
            destination: HomeCardPlaceholderView(title: "自动化", subtitle: "自动流程与快捷指令")
        )
    ]
}

/// 占位目标页：诚实空状态（不塞假数据），待对应功能组替换。
struct HomeCardPlaceholderView: View {
    let title: String
    let subtitle: String

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("\(title)功能开发中")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .padding(.horizontal, 16)
                .listRowBackground(Color.clear)
            } header: {
                Text(title)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}