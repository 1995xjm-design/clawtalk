import SwiftUI
import MarkdownUI

// MARK: - 搜索 ViewModel

/// 记忆搜索 ViewModel：网关调用与 ToolsViewModel.searchMemory 同款
/// （OpenClawClient.invokeTool(tool: "memory_search")），独立实现、不依赖 ToolsViewModel。
///
/// TODO（主智能体）：若记忆中心需要走 WebSocket 兜底，可把 gatewayConnection 用于
/// GatewayConnection 的 RPC 降级（当前与 ToolsViewModel 保持一致：HTTP /tools/invoke 为主）。
@Observable
@MainActor
final class MemorySearchTabViewModel {
    var query = ""
    var results: [MemorySearchEntry] = []
    var fileContent: MemoryGetResult?
    var isLoading = false
    var errorMessage: String?

    /// 来源过滤（本地按结果 source/path 子串匹配；网关返回 source 语义以服务端为准）。
    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "全部来源"
        case phone = "手机"
        case computer = "电脑"
        case keyboard = "键盘"

        var id: String { rawValue }

        func matches(_ source: String?, path: String) -> Bool {
            guard self != .all else { return true }
            let haystack = "\(source ?? "") \(path)"
            return haystack.contains(rawValue)
        }
    }

    /// 时间过滤（作为可选参数传给网关；网关不支持时会被忽略，界面如实标注，不做本地假过滤）。
    enum TimeFilter: String, CaseIterable, Identifiable {
        case all = "全部时间"
        case today = "今天"
        case week = "近 7 天"
        case month = "近 30 天"

        var id: String { rawValue }

        var startDate: Date? {
            let calendar = Calendar.current
            let todayStart = calendar.startOfDay(for: Date())
            switch self {
            case .all: return nil
            case .today: return todayStart
            case .week: return calendar.date(byAdding: .day, value: -6, to: todayStart)
            case .month: return calendar.date(byAdding: .day, value: -29, to: todayStart)
            }
        }
    }

    var sourceFilter: SourceFilter = .all
    var timeFilter: TimeFilter = .all

    private let client = OpenClawClient()
    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
    }

    private var gatewayURL: String { settings.settings.gatewayURL }
    private var token: String { settings.gatewayToken }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var args: [String: JSONValue] = [
                "query": .string(trimmed),
                "maxResults": .int(20),
                "minScore": .double(0.15)
            ]
            // 时间过滤：网关 memory_search 支持 startDate 时生效；不支持会被网关忽略（诚实：不过滤不报错）
            if let start = timeFilter.startDate {
                args["startDate"] = .string(Self.isoString(start))
            }

            let data = try await client.invokeTool(
                tool: "memory_search",
                args: args,
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<MemorySearchResults>.self, from: data)
            var all = wrapper.details?.results ?? []
            if sourceFilter != .all {
                all = all.filter { sourceFilter.matches($0.source, path: $0.path) }
            }
            results = all
        } catch {
            results = []
            errorMessage = AppErrorText.localized(error.localizedDescription)
        }
    }

    func getFile(path: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let data = try await client.invokeTool(
                tool: "memory_get",
                args: ["path": .string(path)],
                gatewayURL: gatewayURL,
                token: token
            )
            let wrapper = try JSONDecoder().decode(ToolResultWrapper<MemoryGetResult>.self, from: data)
            fileContent = wrapper.details
        } catch {
            errorMessage = AppErrorText.localized(error.localizedDescription)
        }
    }

    private static func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - 搜索 Tab

/// 搜索 Tab：搜索框 + 时间/来源过滤 + 结果列表，点结果进入轻量 Markdown 详情。
struct MemorySearchTabView: View {
    @Bindable var viewModel: MemorySearchTabViewModel

    var body: some View {
        List {
            Section {
                TextField("搜索记忆内容...", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit {
                        Task { await viewModel.search() }
                    }

                HStack(spacing: 12) {
                    Picker("来源", selection: $viewModel.sourceFilter) {
                        ForEach(MemorySearchTabViewModel.SourceFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("时间", selection: $viewModel.timeFilter) {
                        ForEach(MemorySearchTabViewModel.TimeFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .font(.caption)

                Button {
                    Task { await viewModel.search() }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.openClawRed)
            } header: {
                Text("关键词")
            } footer: {
                Text("时间过滤由网关 memory_search 支持时生效；来源过滤按结果自带 source 匹配。")
            }

            if viewModel.results.isEmpty && !viewModel.isLoading {
                Section {
                    ContentUnavailableView(
                        viewModel.query.isEmpty ? "搜索记忆" : "没有匹配结果",
                        systemImage: "brain.head.profile",
                        description: Text(
                            viewModel.query.isEmpty
                                ? "搜索智能体记忆中存储的知识。"
                                : "换个关键词或放宽过滤条件试试。"
                        )
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            ForEach(viewModel.results) { entry in
                NavigationLink {
                    MemoryHubDetailView(viewModel: viewModel, path: entry.path)
                } label: {
                    resultRow(entry)
                }
            }
        }
        .listStyle(.insetGrouped)
        .onChange(of: viewModel.sourceFilter) { _, _ in
            Task { await viewModel.search() }
        }
        .onChange(of: viewModel.timeFilter) { _, _ in
            Task { await viewModel.search() }
        }
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.errorMessage {
                errorBanner(error)
            }
        }
    }

    private func resultRow(_ entry: MemorySearchEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.path)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.openClawRed)

                Spacer()

                Text(String(format: "%.0f%%", entry.score * 100))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(.systemGray5)))
            }

            Text(entry.snippet)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(3)

            if let source = entry.source {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
            Text(message)
                .font(.caption)
                .lineLimit(2)
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }
}

// MARK: - 轻量详情

/// 轻量版记忆详情：与 MemoryDetailView 同款样式（Markdown 主题 .openClaw），独立实现。
struct MemoryHubDetailView: View {
    @Bindable var viewModel: MemorySearchTabViewModel
    let path: String

    var body: some View {
        ScrollView {
            if viewModel.isLoading {
                ProgressView()
                    .padding(.top, 40)
            } else if let result = viewModel.fileContent {
                if let error = result.error {
                    ContentUnavailableView(
                        "Error",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if path.hasSuffix(".md") {
                    Markdown(result.text)
                        .markdownTheme(.openClaw)
                        .textSelection(.enabled)
                        .padding()
                } else {
                    Text(result.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView(
                    "Error",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            }
        }
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.getFile(path: path)
        }
    }
}
