import Foundation
import Observation

/// 文章草稿本地存储：UserDefaults（JSON）增删改查。
@Observable
@MainActor
final class WritingStore {
    private(set) var drafts: [ArticleDraft] = []

    private let storageKey = "clawtalk_writing_drafts_v1"

    init() {
        load()
    }

    // MARK: - 查询

    /// 全部文章数（卡片摘要用）。
    var totalCount: Int {
        drafts.count
    }

    /// 最近一篇的更新时间（卡片摘要用；无文章返回 nil，卡片显示诚实空状态）。
    var lastDraftDate: Date? {
        drafts.first?.updatedAt
    }

    func draft(id: UUID) -> ArticleDraft? {
        drafts.first { $0.id == id }
    }

    // MARK: - 增删改

    @discardableResult
    func add(_ draft: ArticleDraft) -> ArticleDraft {
        drafts.insert(draft, at: 0)
        persist()
        return draft
    }

    func update(_ draft: ArticleDraft) {
        guard let index = drafts.firstIndex(where: { $0.id == draft.id }) else { return }
        drafts[index] = draft
        persist()
    }

    func delete(id: UUID) {
        drafts.removeAll { $0.id == id }
        persist()
    }

    /// 详情页编辑后刷新标题/正文/字数/更新时间并落库；返回刷新后的草稿。
    @discardableResult
    func refresh(id: UUID, title: String, content: String) -> ArticleDraft? {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return nil }
        var updated = drafts[index]
        updated.title = title
        updated.content = content
        updated.wordCount = content.count
        updated.updatedAt = Date()
        drafts[index] = updated
        persist()
        return updated
    }

    // MARK: - 持久化（UserDefaults JSON）

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ArticleDraft].self, from: data) else {
            drafts = []
            return
        }
        drafts = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(drafts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
