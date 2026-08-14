import SwiftUI

/// 副主页「我的记忆」卡：档案条目数 + 今日新增角标 + 最近沉淀滚动摘要 + 大脑图标，点开进入记忆中心。
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

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        _profileStore = State(initialValue: MemoryProfileStore(settings: settings))
    }

    var body: some View {
        NavigationLink {
            MemoryHubView(settings: settings, gatewayConnection: gatewayConnection)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                titleRow
                recentSection
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
            await profileStore.syncToGateway()
        }
    }

    // MARK: - 头部：图标 + 今日新增角标 + 箭头

    private var headerRow: some View {
        HStack(alignment: .top) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "brain.head.profile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.purple)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if profileStore.todayAddedCount > 0 {
                    Text("今日 +\(profileStore.todayAddedCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 6, y: -6)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 标题 + 摘要

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("我的记忆")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("\(profileStore.profiles.count) 条档案 · 最近沉淀 \(profileStore.recentEntries.count) 条")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 最近沉淀滚动摘要（直接读 MemoryProfileStore，无需点击进入）

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近沉淀")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            if profileStore.recentEntries.isEmpty {
                Text("暂无沉淀条目")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(profileStore.recentEntries.prefix(6)) { entry in
                            HStack(spacing: 6) {
                                Image(systemName: entry.category.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(Color.purple)
                                    .frame(width: 12)

                                Text(snippet(entry.summary))
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 86)
            }
        }
    }

    private func snippet(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 22 ? String(trimmed.prefix(22)) + "…" : trimmed
    }
}
