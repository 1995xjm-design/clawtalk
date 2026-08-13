import Foundation

/// 电脑端记忆快照（电脑 8899 `/memory-sync` 返回的 JSON 结构）。
/// 字段与电脑侧约定一致：sharedMemorySummary = shared-memory 摘要，
/// layeredMemorySummary = OpenClaw 分层记忆摘要，dialogueSnippet = 最近对话片段。
struct ComputerMemorySnapshot: Codable, Equatable {
    var version: Int
    var generatedAt: Date
    var sharedMemorySummary: String?
    var layeredMemorySummary: String?
    var dialogueSnippet: [String]?

    /// 合并后的记忆摘要（供注入；两段都有时用换行拼接）。
    var mergedSummary: String {
        var parts: [String] = []
        if let sharedMemorySummary, !sharedMemorySummary.isEmpty {
            parts.append(sharedMemorySummary)
        }
        if let layeredMemorySummary, !layeredMemorySummary.isEmpty {
            parts.append(layeredMemorySummary)
        }
        return parts.joined(separator: "\n")
    }
}

/// 手机 ↔ 电脑记忆同步：
/// - 拉电脑快照：8899 `/memory-sync`（回退同名静态文件），成功缓存本地
/// - 上传手机档案：POST `/memory-sync/upload`（电脑端未实现时诚实报错，本地保留）
/// - 缓存供直连 DeepSeek 注入（computerSummary / recentDialogueSnippet）
/// 诚实原则：拉取失败时返回上次缓存（或 nil），绝不伪造快照。
@MainActor
@Observable
final class MemorySyncService {
    static let shared = MemorySyncService()

    private(set) var cachedSnapshot: ComputerMemorySnapshot?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var lastFetchedAt: Date?

    private let defaults = UserDefaults.standard
    private let snapshotKey = "memory_sync_cached_snapshot_v1"

    private init() {
        loadCache()
    }

    /// 电脑快照摘要（供记忆注入；无缓存时返回 nil，调用方诚实降级为纯本地档案）。
    var computerSummary: String? {
        guard let merged = cachedSnapshot?.mergedSummary, !merged.isEmpty else { return nil }
        return merged
    }

    /// 最近对话片段（供记忆注入）。
    var recentDialogueSnippet: [String] {
        cachedSnapshot?.dialogueSnippet ?? []
    }

    // MARK: - 拉取电脑快照

    /// 拉取并缓存电脑记忆快照。baseURL：电脑文件服务根（如 http://host:8899）。
    @discardableResult
    func fetchComputerSnapshot(baseURL: URL) async -> ComputerMemorySnapshot? {
        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            let snapshot = try await Self.downloadSnapshot(baseURL: baseURL)
            cachedSnapshot = snapshot
            lastFetchedAt = Date()
            saveCache()
            return snapshot
        } catch {
            lastError = "拉取电脑记忆失败：\(error.localizedDescription)"
            return cachedSnapshot
        }
    }

    // MARK: - 上传手机档案

    /// 上传手机档案 JSON 快照到电脑（POST /memory-sync/upload）。
    func uploadPhoneSnapshot(exportData: Data, baseURL: URL) async -> Bool {
        lastError = nil
        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("memory-sync/upload"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = exportData

            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                lastError = "上传失败（\(http.statusCode)）：电脑端暂不支持 /memory-sync/upload"
                return false
            }
            return true
        } catch {
            lastError = "上传失败：\(error.localizedDescription)"
            return false
        }
    }

    // MARK: - 内部

    private static func downloadSnapshot(baseURL: URL) async throws -> ComputerMemorySnapshot {
        let candidates = [
            baseURL.appendingPathComponent("memory-sync"),
            baseURL.appendingPathComponent("clawtalk-memory-snapshot.json")
        ]
        var lastError: Error?
        for url in candidates {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    return try decoder.decode(ComputerMemorySnapshot.self, from: data)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotFindHost)
    }

    private func loadCache() {
        guard let data = defaults.data(forKey: snapshotKey) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        cachedSnapshot = try? decoder.decode(ComputerMemorySnapshot.self, from: data)
    }

    private func saveCache() {
        guard let snapshot = cachedSnapshot else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
    }
}
