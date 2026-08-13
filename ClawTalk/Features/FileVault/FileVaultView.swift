import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 文件保险箱列表页：
/// - 重要文件列表：名称 / 大小 / 来源 / 剩余天数（诚实状态），行内「检查」按钮 + 滑动取消标记
/// - 诚实空状态：没有登记时如实显示，并给「从已下载文件选择 / 从文件导入」入口
/// - 点行进详情：QuickLook 预览 / 分享 / 改检查周期 / 备注 / 文件丢失提示
///
/// 与文件传输联动：FileTransferView 未改动（只读参考），本页提供
/// 「从已下载文件选择」入口（读 FileTransferViewModel.downloadedFiles）。
/// 主智能体如需在 FileTransferView 下载完成时直接弹「标记重要」，
/// 可在 FileTransferView.startDownload 成功后调 FileVaultStore.shared.markImportant(...)。
struct FileVaultView: View {
    @State private var store: FileVaultStore
    @State private var showAddSheet = false
    @State private var activeAlert: FileVaultActiveAlert?

    init(store: FileVaultStore? = nil) {
        _store = State(initialValue: store ?? FileVaultStore.shared)
    }

    var body: some View {
        List {
            if store.files.isEmpty {
                emptySection
            } else {
                filesSection
            }

            if store.notificationPermissionDenied {
                Section {
                    Label("通知权限被拒绝，到期不会收到本地提醒，但仍可在本页看到待检查列表。", systemImage: "bell.slash.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("文件保险箱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("登记重要文件")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            NavigationStack {
                AddImportantFileSheet(store: store)
            }
        }
        .navigationDestination(for: FileVaultRoute.self) { route in
            if let file = store.files.first(where: { $0.id == route.fileID }) {
                FileVaultDetailView(store: store, fileID: route.fileID)
            } else {
                Text("该文件已取消标记")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: store.errorMessage) { _, newValue in
            if let newValue {
                activeAlert = FileVaultActiveAlert(title: "出错了", message: newValue)
            }
        }
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好")) {
                    store.errorMessage = nil
                }
            )
        }
        .onAppear {
            _ = store.checkDue()
        }
    }

    // MARK: - 诚实空状态

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("还没有重要文件")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("把下载或导入的文件标记为「重要」，到期提醒你检查，防止文件悄悄丢失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    showAddSheet = true
                } label: {
                    Label("登记第一个重要文件", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - 重要文件列表

    private var filesSection: some View {
        Section {
            ForEach(store.files) { file in
                fileRow(file)
            }
        } header: {
            Text("重要文件")
        } footer: {
            Text("「检查」会记录本次检查时间并重新安排到期提醒；滑动行可取消标记（不会删除文件本身）。")
        }
    }

    private func fileRow(_ file: ImportantFile) -> some View {
        HStack(spacing: 10) {
            NavigationLink(value: FileVaultRoute(fileID: file.id)) {
                HStack(spacing: 12) {
                    Image(systemName: file.source.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(rowIconColor(for: file))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.fileName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 6) {
                            Text(FileTransferViewModel.formatBytes(file.size))
                            Text("·")
                            Text(file.source.displayName)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        statusLine(file)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                store.checkIn(id: file.id)
            } label: {
                Image(systemName: file.isDue ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(file.isDue ? Color.orange : Color.green)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("标记「\(file.fileName)」为已检查")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.unmark(id: file.id)
            } label: {
                Label("取消标记", systemImage: "lock.slash")
            }
        }
    }

    private func rowIconColor(for file: ImportantFile) -> Color {
        file.isDue ? .orange : .indigo
    }

    @ViewBuilder
    private func statusLine(_ file: ImportantFile) -> some View {
        let days = file.daysUntilDue
        if file.lastCheckedAt == nil {
            Text(days > 0 ? "尚未检查 · 剩余 \(days) 天" : "尚未检查 · 已到期")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else if days > 0 {
            Text("剩余 \(days) 天检查")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if days == 0 {
            Text("今天到期，请检查")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            Text("已逾期 \(-days) 天，请检查")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

/// 列表到详情的导航值（独立类型，避免与全局 String 导航注册冲突）。
private struct FileVaultRoute: Hashable {
    let fileID: String
}

/// 登记入口 sheet：从已下载文件选择（文件传输联动）+ 从「文件」App 导入。
private struct AddImportantFileSheet: View {
    let store: FileVaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var transferViewModel: FileTransferViewModel
    @State private var showImporter = false

    init(store: FileVaultStore) {
        self.store = store
        // FileTransferViewModel 需要 SettingsStore；这里只读本地已下载列表，新建实例即可。
        _transferViewModel = State(initialValue: FileTransferViewModel(settings: SettingsStore()))
    }

    var body: some View {
        List {
            Section {
                Text("把文件标记为「重要」后，会按周期提醒你检查，防止文件悄悄丢失。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("从已下载文件选择") {
                if transferViewModel.downloadedFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("暂无已下载文件", systemImage: "tray")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("请先到「文件传输」下载电脑端文件，再回来标记。")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(transferViewModel.downloadedFiles) { localFile in
                        Button {
                            markDownloaded(localFile)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.indigo)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(localFile.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Text(FileTransferViewModel.formatBytes(localFile.size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: store.isMarked(fileName: localFile.name) ? "checkmark.circle.fill" : "lock.badge.plus")
                                    .foregroundStyle(store.isMarked(fileName: localFile.name) ? Color.green : Color.indigo)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isMarked(fileName: localFile.name))
                    }
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("从「文件」App 导入", systemImage: "folder")
                }
            } footer: {
                Text("导入的文件会复制一份到 App 保险箱目录，原文件位置不影响。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("登记重要文件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    dismiss()
                }
            }
        }
        .onAppear {
            transferViewModel.reloadDownloadedFiles()
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            handleImport(result)
        }
    }

    private func markDownloaded(_ localFile: FileTransferViewModel.LocalFile) {
        if store.markImportant(fileName: localFile.name, source: .download, localURL: localFile.url) {
            dismiss()
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            if store.markImportant(fileName: url.lastPathComponent, source: .imported, localURL: url) {
                dismiss()
            }
        case .failure(let error):
            store.errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }
}

/// 重要文件详情：预览 / 分享 / 改检查周期 / 备注 / 检查 / 取消标记。
private struct FileVaultDetailView: View {
    let store: FileVaultStore
    let fileID: String

    @Environment(\.dismiss) private var dismiss
    @State private var noteText: String
    @State private var intervalDays: Int
    @State private var previewItem: FileVaultPreviewItem?
    @State private var showUnmarkConfirm = false

    init(store: FileVaultStore, fileID: String) {
        self.store = store
        self.fileID = fileID
        let file = store.files.first { $0.id == fileID }
        _noteText = State(initialValue: file?.note ?? "")
        _intervalDays = State(initialValue: file?.checkIntervalDays ?? 7)
    }

    private var file: ImportantFile? {
        store.files.first { $0.id == fileID }
    }

    var body: some View {
        Group {
            if let file {
                content(file)
            } else {
                Text("该文件已取消标记")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(file?.fileName ?? "文件详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ file: ImportantFile) -> some View {
        List {
            Section("文件") {
                HStack(spacing: 12) {
                    Image(systemName: file.source.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.fileName)
                            .font(.body.weight(.semibold))
                        Text("\(FileTransferViewModel.formatBytes(file.size)) · \(file.source.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("登记时间", value: Self.dateText(file.markedAt))
                LabeledContent("上次检查", value: file.lastCheckedAt.map(Self.dateText) ?? "尚未检查")
            }

            Section("检查") {
                LabeledContent("下次检查", value: nextCheckText(file))
                Picker("检查周期", selection: $intervalDays) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { days in
                        Text("每 \(days) 天").tag(days)
                    }
                }
                .onChange(of: intervalDays) { _, newValue in
                    store.updateCheckInterval(days: newValue, for: file.id)
                }
                Button {
                    store.checkIn(id: file.id)
                } label: {
                    Label(file.isDue ? "检查并重新计时" : "标记为已检查", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(file.isDue ? Color.orange : Color.green)
                }
            }

            Section("备注") {
                TextField("备注（可选）", text: $noteText, axis: .vertical)
                    .lineLimit(2...4)
                    .onChange(of: noteText) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        store.updateNote(trimmed.isEmpty ? nil : newValue, for: file.id)
                    }
            }

            Section {
                if let url = file.localURL, store.fileExists(file) {
                    Button {
                        previewItem = FileVaultPreviewItem(url: url)
                    } label: {
                        Label("预览", systemImage: "eye")
                    }
                    ShareLink(item: url) {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("文件已丢失：本地找不到这个文件，请从来源重新获取。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("文件状态")
            } footer: {
                Text(statusFooter(file))
            }

            Section {
                Button("取消重要标记", role: .destructive) {
                    showUnmarkConfirm = true
                }
            } footer: {
                Text("取消标记只移除登记与到期提醒，不会删除文件本身。")
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("取消标记「\(file.fileName)」？", isPresented: $showUnmarkConfirm, titleVisibility: .visible) {
            Button("取消标记", role: .destructive) {
                store.unmark(id: file.id)
                dismiss()
            }
            Button("不取消", role: .cancel) {}
        }
        .sheet(item: $previewItem) { item in
            FileVaultQuickLook(url: item.url)
        }
    }

    private func nextCheckText(_ file: ImportantFile) -> String {
        let days = file.daysUntilDue
        if days > 0 {
            return "\(Self.dateText(file.dueDate))（剩余 \(days) 天）"
        }
        if days == 0 {
            return "今天到期，请检查"
        }
        return "已逾期 \(-days) 天，请尽快检查"
    }

    private func statusFooter(_ file: ImportantFile) -> String {
        guard let path = file.localPath else { return "未记录本地路径。" }
        if path.hasPrefix(store.vaultDirectory.path) {
            return "此文件已复制到 App 保险箱目录（Application Support/FileVault），卸载 App 前请先备份导出。"
        }
        return "此文件引用自 App 文档目录，如被「文件传输」删除，这里会提示文件丢失。"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }
}

/// 系统 QuickLook 预览（文件传输页的实现是 private，这里独立一份）。
private struct FileVaultQuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.title = url.lastPathComponent
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: context.coordinator,
            action: #selector(FileVaultQuickLook.Coordinator.close)
        )
        let navigationController = UINavigationController(rootViewController: controller)
        context.coordinator.dismiss = { [weak navigationController] in
            navigationController?.dismiss(animated: true)
        }
        return navigationController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        var dismiss: (() -> Void)?

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }

        @objc func close() {
            dismiss?()
        }
    }
}

private struct FileVaultPreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct FileVaultActiveAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}