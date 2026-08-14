import SwiftUI

/// 副主页「知识库」卡：最近问答数 + 今日角标 + 最新问题预览，点开进入问答页。
///
/// 接线说明（主智能体）：
/// 1. 在 `HomeTabView.swift` 的快捷卡片网格（LazyVGrid）中，紧跟「我的记忆」卡之后加入：
///    `KBCardView(settings: settings, gatewayConnection: gatewayConnection)`
/// 2. 若希望走 agent 增强（智能体基于记忆回答），传入 `agentId`
///    （默认 nil = 纯检索拼接，不调智能体）。
struct KBCardView: View {
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?
    private let agentId: String?

    @State private var store: KBStore

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil, agentId: String? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        self.agentId = agentId
        _store = State(initialValue: KBStore(settings: settings, agentId: agentId))
    }

    var body: some View {
        NavigationLink {
            KBView(settings: settings, gatewayConnection: gatewayConnection, agentId: agentId)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                titleRow
                if let latest = store.questions.last {
                    latestRow(latest)
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
    }

    // MARK: - 头部：图标 + 今日角标 + 箭头

    private var headerRow: some View {
        HStack(alignment: .top) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.teal)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                if store.todayCount > 0 {
                    Text("今日 +\(store.todayCount)")
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
            Text("知识库问答")
                .font(.headline)
                .foregroundStyle(.primary)

            Text("\(store.totalCount) 条问答 · 答案来自记忆库")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 最新提问预览

    private func latestRow(_ entry: KBQuestion) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("最近提问")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            Text(entry.question)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
    }
}
