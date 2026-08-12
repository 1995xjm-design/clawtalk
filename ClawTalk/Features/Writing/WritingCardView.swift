import SwiftUI

/// 主页「语音写文章」卡：显示最近文章数，点击进入文章列表/新建。
/// 主智能体接线：放进主页快捷卡片网格即可（自带 NavigationLink → WritingListView）：
///     WritingCardView(settingsStore: settings)
struct WritingCardView: View {
    @State private var store: WritingStore
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore = SettingsStore(), store: WritingStore? = nil) {
        self.settingsStore = settingsStore
        _store = State(initialValue: store ?? WritingStore())
    }

    var body: some View {
        NavigationLink {
            WritingListView(settingsStore: settingsStore, store: store)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Color.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Spacer(minLength: 0)

                    if store.totalCount > 0 {
                        Text("最近 \(store.totalCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.indigo, in: Capsule())
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text("语音写文章")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    summaryText
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
    }

    /// 摘要：有文章显示数量与最近日期；无文章显示诚实空状态。
    @ViewBuilder
    private var summaryText: some View {
        if let lastDate = store.lastDraftDate {
            Text("已有 \(store.totalCount) 篇文章 · 最近 \(Self.shortDate(lastDate))")
        } else {
            Text("还没有文章，口述要点生成一篇")
        }
    }

    private static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

/// 文章列表页：按更新时间倒序，每条显示标题/语气/字数，点击看详情。
struct WritingListView: View {
    @State private var store: WritingStore
    private let settingsStore: SettingsStore

    init(
        settingsStore: SettingsStore = SettingsStore(),
        store: WritingStore? = nil
    ) {
        self.settingsStore = settingsStore
        _store = State(initialValue: store ?? WritingStore())
    }

    var body: some View {
        Group {
            if store.drafts.isEmpty {
                emptyState
            } else {
                draftList
            }
        }
        .navigationTitle("语音写文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    WritingComposeView(settingsStore: settingsStore, writingStore: store)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建文章")
            }
        }
    }

    // MARK: - 列表

    private var draftList: some View {
        List {
            ForEach(store.drafts) { draft in
                NavigationLink {
                    WritingDetailView(draft: draft, store: store, settings: settingsStore)
                } label: {
                    WritingListRow(draft: draft)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 空状态（诚实，不塞假数据）

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有文章")
                .font(.headline)
            Text("点右上角 + 录口述要点，AI 会按语气扩写成完整文章，可编辑、分享、朗读。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列表行：标题（本地降级带标注）+ 语气/字数。
private struct WritingListRow: View {
    let draft: ArticleDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(draft.title.isEmpty ? "未命名文章" : draft.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !draft.generatedByAI {
                    Text("本地生成")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 12) {
                Label(draft.tone.rawValue, systemImage: "textformat")
                Label(draft.wordCountText, systemImage: "character.cursor.ibeam")
                Label("\(draft.paragraphCount) 段", systemImage: "paragraphsign")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
