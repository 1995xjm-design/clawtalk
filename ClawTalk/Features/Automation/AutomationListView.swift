import SwiftUI

/// 自动化任务列表（本机任务 + 预留网关 cron 同步）。
///
/// 主智能体接线（副主页「自动化」卡片，三选一）：
/// 1. fullScreenCover / sheet：
///    .sheet(isPresented: $showAutomation) { NavigationStack { AutomationListView(settings: settingsStore) } }
/// 2. NavigationLink（在已有 NavigationStack 内）：
///    NavigationLink { AutomationListView(settings: settingsStore) } label: { Label("自动化", systemImage: "clock.badge") }
/// 3. 直接使用本文件底部的 AutomationEntryButton（自带 fullScreenCover 包装）
struct AutomationListView: View {
    @State private var viewModel: AutomationViewModel
    @State private var showCreate = false
    private let settings: SettingsStore?

    init(settings: SettingsStore? = nil) {
        self.settings = settings
        _viewModel = State(initialValue: AutomationViewModel(settings: settings))
    }

    var body: some View {
        List {
            if viewModel.tasks.isEmpty && !viewModel.isLoading {
                ContentUnavailableView {
                    Label("暂无自动化任务", systemImage: "clock.badge")
                } description: {
                    Text("说一句「每天收盘后总结股票」，到点自动运行并把结果推送到手机。\n点右上角「+」新建任务。任务先保存在本机，网关 cron 接口接线后自动同步执行。")
                } actions: {
                    Button("新建任务") {
                        showCreate = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            ForEach(viewModel.tasks) { task in
                taskRow(task)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            viewModel.deleteTask(id: task.id)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("自动化")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.openClawRed)
                }
                .accessibilityLabel("新建任务")

            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                AutomationCreateView(viewModel: viewModel)
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading && viewModel.tasks.isEmpty {
                ProgressView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let note = viewModel.gatewayStatusText {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    // MARK: - 行

    private func taskRow(_ task: AutomationTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Label(task.scheduleDescription, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let next = task.nextRunAt {
                    Label(formatted(next), systemImage: "clock.fill")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.openClawRed))
                } else {
                    Text("下次：待网关排程")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if task.gatewaySync == .failed {
                    Label("网关未同步", systemImage: "exclamationmark.icloud")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                lastResultLine(task)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 8) {
                Toggle("", isOn: enabledBinding(for: task))
                    .labelsHidden()
                    .tint(.openClawRed)

                NavigationLink {
                    AutomationHistoryView(task: task, viewModel: viewModel)
                } label: {
                    Label("历史", systemImage: "clock.arrow.circlepath")
                        .font(.caption2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func lastResultLine(_ task: AutomationTask) -> some View {
        if let result = task.lastResult {
            HStack(spacing: 4) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.succeeded ? .green : .red)
                Text("上次：\(result.summary)")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        } else {
            Text("上次：尚未运行")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func enabledBinding(for task: AutomationTask) -> Binding<Bool> {
        Binding(
            get: { task.enabled },
            set: { viewModel.setEnabled($0, for: task.id) }
        )
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - 副主页入口（主智能体接线用）

/// 副主页「自动化」卡片入口：Button + fullScreenCover。
/// 用法：把本组件放进 ChannelListView 的工具栏/卡片区即可。
struct AutomationEntryButton: View {
    let settings: SettingsStore?
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("自动化", systemImage: "clock.badge")
                .foregroundStyle(Color.openClawRed)
        }
        .fullScreenCover(isPresented: $isPresented) {
            NavigationStack {
                AutomationListView(settings: settings)
            }
        }
    }
}

// MARK: - 运行历史

private struct AutomationHistoryView: View {
    let task: AutomationTask
    @Bindable var viewModel: AutomationViewModel

    var body: some View {
        let records = viewModel.history(for: task.id)
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "暂无运行记录",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("任务每次运行后，网关会把结果回传到这里。\n（网关 cron 接口接线后自动同步）")
                )
            } else {
                List(records) { record in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: record.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(record.succeeded ? .green : .red)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatted(record.runAt))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(record.summary)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("运行历史")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
