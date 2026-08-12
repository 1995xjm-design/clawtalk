import Foundation
import SwiftUI

/// 第二大脑·记忆中心：档案 / 对话沉淀 / 搜索 三 Tab 主页面。
///
/// 入口接线（主智能体）：通过 Features/MemoryHub/MemoryHubCardView.swift 挂到副主页，
/// 由卡片 push 本页（依赖副主页已有 NavigationStack，本页不自建，避免嵌套导航栏）。
struct MemoryHubView: View {
    enum HubTab: String, CaseIterable, Identifiable {
        case profile = "档案"
        case timeline = "对话沉淀"
        case search = "搜索"

        var id: String { rawValue }
    }

    @State private var selectedTab: HubTab = .profile
    @State private var profileStore: MemoryProfileStore
    @State private var timelineStore: MemoryTimelineStore
    @State private var searchViewModel: MemorySearchTabViewModel

    private let settings: SettingsStore
    private let gatewayConnection: GatewayConnection?

    init(settings: SettingsStore, gatewayConnection: GatewayConnection? = nil) {
        self.settings = settings
        self.gatewayConnection = gatewayConnection
        _profileStore = State(initialValue: MemoryProfileStore())
        _timelineStore = State(initialValue: MemoryTimelineStore(settings: settings))
        _searchViewModel = State(initialValue: MemorySearchTabViewModel(settings: settings, gatewayConnection: gatewayConnection))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("记忆中心", selection: $selectedTab) {
                ForEach(HubTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch selectedTab {
            case .profile:
                MemoryProfileTabView(store: profileStore)
            case .timeline:
                MemoryTimelineTabView(store: timelineStore)
            case .search:
                MemorySearchTabView(viewModel: searchViewModel)
            }
        }
        .navigationTitle("第二大脑")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 档案 Tab

/// 档案 Tab：偏好/项目/事实/灵感 卡片列表（每张显示分类 + 摘要 + 来源 + 时间）。
private struct MemoryProfileTabView: View {
    let store: MemoryProfileStore

    private var grouped: [(category: MemoryProfile.Category, entries: [MemoryProfile])] {
        MemoryProfile.Category.displayOrder.compactMap { category in
            let entries = store.profiles.filter { $0.category == category }
            return entries.isEmpty ? nil : (category, entries)
        }
    }

    var body: some View {
        Group {
            if store.profiles.isEmpty {
                ContentUnavailableView(
                    "还没有档案",
                    systemImage: "person.text.rectangle",
                    description: Text("从手机对话中按规则自动聚合：偏好 / 项目 / 事实 / 灵感。有对话后点右上角「重新聚合」。")
                )
            } else {
                List {
                    ForEach(grouped, id: \.category) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                profileRow(entry)
                            }
                        } header: {
                            Label(group.category.rawValue, systemImage: group.category.systemImage)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.refreshFromConversations()
                    Task { await store.syncToGateway() }
                } label: {
                    Label("重新聚合", systemImage: "arrow.clockwise")
                }
            }
        }
        .task {
            store.refreshFromConversations()
            await store.syncToGateway()
        }
    }

    private func profileRow(_ entry: MemoryProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(entry.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack(spacing: 6) {
                Text(entry.source)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(entry.lastUpdated, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 对话沉淀 Tab

/// 对话沉淀时间线条目：来源（手机/电脑/键盘）+ 时间 + 内容。
struct MemoryTimelineEntry: Identifiable, Equatable {
    enum Source: String, CaseIterable, Identifiable {
        case phone = "手机"
        case computer = "电脑"
        case keyboard = "键盘"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .phone: return "iphone"
            case .computer: return "desktopcomputer"
            case .keyboard: return "keyboard"
            }
        }
    }

    let id: UUID
    let date: Date
    let source: Source
    let channelName: String
    let text: String
}

/// 对话沉淀数据源（诚实聚合，无数据即空）：
/// - 手机：本机 ConversationStore 各频道真实用户消息
/// - 电脑：Codex/Claude 同步桥（http://<网关主机>:18991|18992/sync，与 SyncChatViewModel 同源，
///   尽力拉取，失败不影响手机数据）
/// - 键盘：键盘扩展当前不保存打字日志，无数据时界面如实说明
@Observable
@MainActor
final class MemoryTimelineStore {
    private(set) var entries: [MemoryTimelineEntry] = []
    private(set) var sourcesWithData: Set<MemoryTimelineEntry.Source> = []
    var isLoading = false
    var errorMessage: String?

    private let settings: SettingsStore?

    init(settings: SettingsStore?) {
        self.settings = settings
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        var merged = loadPhoneEntries()
        var available: Set<MemoryTimelineEntry.Source> = merged.isEmpty ? [] : [.phone]

        if let settings,
           !settings.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let computerEntries = await loadComputerEntries(gatewayURL: settings.settings.gatewayURL)
            if !computerEntries.isEmpty { available.insert(.computer) }
            merged += computerEntries
        }

        entries = merged.sorted { $0.date > $1.date }
        sourcesWithData = available
        errorMessage = nil
    }

    // MARK: - 手机：本地对话

    private func loadPhoneEntries() -> [MemoryTimelineEntry] {
        var result: [MemoryTimelineEntry] = []
        for channel in ChannelStore.shared.channels {
            let messages = ConversationStore.shared.load(channelId: channel.id)
            for message in messages where message.role == .user {
                let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                result.append(MemoryTimelineEntry(
                    id: UUID(),
                    date: message.timestamp,
                    source: .phone,
                    channelName: channel.name,
                    text: text
                ))
            }
        }
        return result
    }

    // MARK: - 电脑：Codex/Claude 同步桥

    private func loadComputerEntries(gatewayURL: String) async -> [MemoryTimelineEntry] {
        let host = SyncChatViewModel.host(from: gatewayURL)
        let endpoints = [
            ("Codex 同步", "http://\(host):18991/sync"),
            ("Claude 同步", "http://\(host):18992/sync")
        ]

        var result: [MemoryTimelineEntry] = []
        for (name, endpoint) in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { continue }
                let decoded = try JSONDecoder().decode(SyncHistoryResponse.self, from: data)
                for item in decoded.messages where item.role.lowercased() == "user" {
                    guard let timestamp = SyncChatViewModel.parseTimestamp(item.ts) else { continue }
                    let text = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    result.append(MemoryTimelineEntry(
                        id: UUID(),
                        date: timestamp,
                        source: .computer,
                        channelName: name,
                        text: text
                    ))
                }
            } catch {
                // 同步桥不可达/未部署：静默跳过，不影响手机数据（整段失败由错误横幅兜底）
            }
        }
        return result
    }
}

/// 对话沉淀 Tab：按日期分组的时间线（来源：手机/电脑/键盘）。
private struct MemoryTimelineTabView: View {
    let store: MemoryTimelineStore

    private var groupedByDay: [(day: Date, entries: [MemoryTimelineEntry])] {
        let calendar = Calendar.current
        var groups: [Date: [MemoryTimelineEntry]] = [:]
        for entry in store.entries {
            let day = calendar.startOfDay(for: entry.date)
            groups[day, default: []].append(entry)
        }
        return groups
            .map { (day: $0.key, entries: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        Group {
            if store.entries.isEmpty {
                if store.isLoading {
                    ProgressView("正在汇总对话沉淀…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "暂无对话沉淀",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(emptyDescription)
                    )
                }
            } else {
                List {
                    ForEach(groupedByDay, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                timelineRow(entry)
                            }
                        } header: {
                            Text(Self.dayTitle(group.day))
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await store.reload()
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.errorMessage {
                errorBanner(error)
            }
        }
        .task {
            await store.reload()
        }
    }

    /// 诚实空状态描述：列出当前有数据的来源，并说明键盘端暂未采集。
    private var emptyDescription: String {
        let available = MemoryTimelineEntry.Source.allCases
            .filter { store.sourcesWithData.contains($0) }
            .map(\.rawValue)
            .joined(separator: "/")
        let base = available.isEmpty
            ? "尚无任何来源的数据。"
            : "已有来源：\(available)，但暂无可沉淀的对话。"
        return base + "键盘端打字日志暂未采集，接入后会自动出现。"
    }

    private func timelineRow(_ entry: MemoryTimelineEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.source.systemImage)
                .font(.caption)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(sourceColor(entry.source))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                HStack(spacing: 6) {
                    Text(entry.source.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(entry.channelName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func sourceColor(_ source: MemoryTimelineEntry.Source) -> Color {
        switch source {
        case .phone: return .blue
        case .computer: return .purple
        case .keyboard: return .orange
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日"
        return formatter.string(from: day)
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
