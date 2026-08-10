import SwiftUI

/// 查找聊天内容：搜索当前频道的本地聊天记录，点击结果跳转定位
struct ChatSearchView: View {
    let messages: [Message]
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Message] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return messages.filter { $0.content.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("输入关键词搜索当前频道的聊天记录")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else if results.isEmpty {
                    Text("未找到相关聊天")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(results) { message in
                        Button {
                            onSelect(message.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: message.role == .user ? "person.fill" : "cpu")
                                        .foregroundStyle(message.role == .user ? .blue : Color.openClawRed)
                                        .font(.caption)
                                    Text(message.role == .user ? "我" : "Claw")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(message.role == .user ? .blue : Color.openClawRed)
                                    Spacer()
                                    Text(message.timestamp, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(highlighted(message.content))
                                    .font(.subheadline)
                                    .lineLimit(3)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("查找聊天内容")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "输入关键词")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 关键词高亮
    private func highlighted(_ text: String) -> AttributedString {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var attributed = AttributedString(text)
        guard !q.isEmpty else { return attributed }
        var searchStart = attributed.startIndex
        while searchStart < attributed.endIndex,
              let range = attributed[searchStart...].range(of: q, options: .caseInsensitive) {
            attributed[range].backgroundColor = .yellow
            attributed[range].foregroundColor = .black
            searchStart = range.upperBound
        }
        return attributed
    }
}
