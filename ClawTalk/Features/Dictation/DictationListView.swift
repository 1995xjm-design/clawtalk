import SwiftUI
import Observation

/// 口述文档列表页：按日期分组，每条显示标题/段落数/要点数，点击看详情。
struct DictationListView: View {
    @State private var store: DictationStore
    private let settingsStore: SettingsStore

    init(
        settingsStore: SettingsStore = SettingsStore(),
        store: DictationStore? = nil
    ) {
        self.settingsStore = settingsStore
        _store = State(initialValue: store ?? DictationStore())
    }

    var body: some View {
        Group {
            if store.notes.isEmpty {
                emptyState
            } else {
                noteList
            }
        }
        .navigationTitle("文档口述")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    DictationRecorderView(settingsStore: settingsStore, dictationStore: store)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建口述文档")
            }
        }
    }

    // MARK: - 列表（按日期分组）

    private var noteList: some View {
        List {
            ForEach(store.groupedByDay) { group in
                Section(header: Text(Self.dayHeader(for: group.day))) {
                    ForEach(group.notes) { note in
                        NavigationLink {
                            DictationDetailView(note: note, store: store)
                        } label: {
                            DictationListRow(note: note)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    /// 日期分组标题：今天 / 昨天 / M月d日 EEEE。
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
            Image(systemName: "doc.text")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("还没有口述文档")
                .font(.headline)
            Text("点右上角 + 录一段口述，AI 会自动整理成分段文档和要点。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列表行：标题（本地降级带标注）+ 段落数/要点数。
private struct DictationListRow: View {
    let note: DictationNote

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(note.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !note.organizedByAI {
                    Text("本地整理")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }
            HStack(spacing: 12) {
                Label("\(note.paragraphCount) 段", systemImage: "paragraphsign")
                Label("\(note.keyPoints.count) 个要点", systemImage: "star")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
