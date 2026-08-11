import SwiftUI

/// 副主页「我的记忆」卡：档案条目数 + 最近对话沉淀摘要 + 大脑图标，点开进入记忆中心。
///
/// 接线说明（主智能体）：
/// 1. `ClawTalkApp.swift` 中 `HomeTabView()` 目前无参创建（约 95 行），需要改为传入
///    `settingsStore` 与 `gatewayConnection`；`HomeTabView` 再把这两个参数透传给本卡片。
/// 2. 在副主页快捷卡片网格中，把 `ReminderCardsPlaceholder.cards` 里
///    `id == "my-memory"` 的占位卡替换为本卡片（直接放进 LazyVGrid 一格即可）：
///    `MemoryHubCardView(settings: settings, gatewayConnection: gatewayConnection)`
/// 3. 本卡片自带 NavigationLink（依赖副主页已有 NavigationStack），不要再包一层
///    `HomeCardView` 的 NavigationLink，避免嵌套导航。
/// 4. 替换后 `ReminderCardsPlaceholder` 中「我的记忆」占位即不再使用。
struct MemoryHubCardView: View {
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?

    @State private var profileStore: MemoryProfileStore
    @State private var timelineStore: MemoryTimelineStore

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        _profileStore = State(initialValue: MemoryProfileStore())
        _timelineStore = State(initialValue: MemoryTimelineStore(settings: settings))
    }

    var body: some View {
        NavigationLink {
            MemoryHubView(settings: settings, gatewayConnection: gatewayConnection)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.purple)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("我的记忆")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .buttonStyle(.plain)
        .task {
            profileStore.refreshFromConversations()
            await timelineStore.reload()
        }
    }

    /// 摘要：档案条目数 + 最近一条对话沉淀（无数据时诚实显示空状态）。
    private var summaryLine: String {
        let profileText = "\(profileStore.profiles.count) 条档案"
        if let latest = timelineStore.entries.first {
            let snippet = latest.text.count > 18 ? String(latest.text.prefix(18)) + "…" : latest.text
            return "\(profileText) · 「\(snippet)」"
        }
        return "\(profileText) · 暂无对话沉淀"
    }
}
