import QuickLook
import SwiftUI

/// 文件传输助手：电脑端 OpenClaw 成果文件（media/outbound）的列表、下载与本地管理。
/// 未启动文件服务时提供「一键启动」（发指令到「文件传输」频道）和「手动说明」引导。
struct FileTransferView: View {
    @State private var viewModel: FileTransferViewModel

    @State private var showManualInstructions = false
    @State private var showImageActionSheet = false
    @State private var pendingImageURL: URL?
    @State private var previewItem: PreviewItem?
    @State private var activeAlert: ActiveAlert?

    init(settings: SettingsStore) {
        _viewModel = State(initialValue: FileTransferViewModel(settings: settings))
    }

    var body: some View {
        Group {
            switch viewModel.serverState {
            case .checking:
                ProgressView("正在检测电脑端文件服务…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unreachable:
                unreachableView
            case .reachable:
                fileList
            }
        }
        .navigationTitle("文件传输助手")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.reloadDownloadedFiles()
            await viewModel.checkServer()
        }
        .refreshable {
            await viewModel.refresh()
        }
        .onChange(of: viewModel.errorMessage) { _, newValue in
            if let newValue {
                activeAlert = ActiveAlert(title: "出错了", message: newValue)
            }
        }
        .alert(item: $activeAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
        .sheet(item: $previewItem) { item in
            QuickLookPreview(url: item.url)
        }
    }

    // MARK: - 服务未启动引导

    private var unreachableView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)

                Text("电脑端文件服务未启动")
                    .font(.title3)
                    .fontWeight(.semibold)

                Text("需要先在电脑端启动文件服务，才能接收 OpenClaw 的任务成果文件。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if viewModel.isSendingStartCommand || viewModel.waitingForServer {
                    VStack(spacing: 10) {
                        ProgressView(viewModel.waitingForServer ? "指令已发送，正在等待电脑端启动服务…" : "正在发送启动指令…")
                        Text("服务启动后会自动刷新文件列表")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } else {
                    Button {
                        Task { await viewModel.sendStartCommand() }
                    } label: {
                        Label("一键启动", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.openClawRed)
                    .disabled(!viewModel.canSendStartCommand)

                    if !viewModel.canSendStartCommand {
                        Text("请先在「设置」中填写网关地址和令牌，才能一键启动。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("手动说明", isExpanded: $showManualInstructions) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("在电脑端手动启动文件服务：")
                            .fontWeight(.semibold)

                        Text("1. 打开 PowerShell，找到文件服务脚本：")
                        Text("C:\\Users\\Youhome\\Documents\\Codex\\2026-08-06\\v4-pro-v4-flash\\fusion-backend\\clawtalk_files_server.py")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(6)

                        Text("2. 运行 Python 启动脚本：")
                        Text("python clawtalk_files_server.py")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(6)

                        Text("3. 脚本默认监听 0.0.0.0:8899，手机与电脑在同一网络（或 Tailscale）即可访问。")
                        Text("4. 服务启动后回到本页，点击「重新检测」即可看到文件列表。")
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 4)

                Button {
                    Task { await viewModel.checkServer() }
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
        }
    }

    // MARK: - 文件列表

    private var fileList: some View {
        List {
            Section {
                if viewModel.remoteFiles.isEmpty {
                    if viewModel.isLoadingFiles {
                        ProgressView("正在加载文件列表…")
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Text("电脑端暂无文件")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(viewModel.remoteFiles) { file in
                        Button {
                            startDownload(file)
                        } label: {
                            remoteFileRow(file)
                        }
                        .disabled(viewModel.downloadingFileName != nil)
                    }
                }
            } header: {
                Text("电脑端文件")
            } footer: {
                Text("点击文件即可下载到 iPhone。图片下载后可选择保存到相册。")
            }

            Section {
                if viewModel.downloadedFiles.isEmpty {
                    Text("还没有下载过文件")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.downloadedFiles) { file in
                        downloadedFileRow(file)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    viewModel.deleteDownloadedFile(file)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                }
            } header: {
                Text("已下载")
            } footer: {
                Text("已下载文件保存在 App 的 files 文件夹，可在「文件」App 中查看。")
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if let name = viewModel.downloadingFileName {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在下载 \(name)…")
                        .font(.subheadline)
                }
                .padding(20)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .confirmationDialog(
            "文件已下载，选择保存方式",
            isPresented: $showImageActionSheet,
            titleVisibility: .visible
        ) {
            Button("保存到相册") {
                guard let url = pendingImageURL else { return }
                Task {
                    if await viewModel.saveImageToPhotoLibrary(url: url) {
                        showHint("已保存到相册。")
                    }
                }
            }
            Button("保存到文件") {
                showHint("文件已保存在 App 内，可在「已下载」或「文件」App 中查看。")
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func remoteFileRow(_ file: FileTransferViewModel.RemoteFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(forExtension: file.ext))
                .font(.title2)
                .foregroundStyle(.openClawRed)
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(FileTransferViewModel.formatBytes(file.size)) · \(FileTransferViewModel.formatTime(millis: file.mtime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.openClawRed)
        }
    }

    private func downloadedFileRow(_ file: FileTransferViewModel.LocalFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconName(forExtension: file.url.pathExtension))
                .font(.title2)
                .foregroundStyle(.openClawRed)
                .frame(width: 36, height: 36)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)

            Button {
                previewItem = PreviewItem(url: file.url)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(FileTransferViewModel.formatBytes(file.size)) · \(FileTransferViewModel.formatDate(file.modifiedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            ShareLink(item: file.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 交互

    private func startDownload(_ file: FileTransferViewModel.RemoteFile) {
        Task {
            guard let url = await viewModel.downloadFile(file) else { return }
            if FileTransferViewModel.isImage(ext: file.ext) {
                pendingImageURL = url
                showImageActionSheet = true
            } else {
                showHint("已保存到「文件」App，可在 文件 App > 我的 iPhone > ClawTalk > files 中查看。")
            }
        }
    }

    private func showHint(_ message: String) {
        activeAlert = ActiveAlert(title: "提示", message: message)
    }

    private func iconName(forExtension ext: String) -> String {
        if FileTransferViewModel.isImage(ext: ext) {
            return "photo"
        }
        switch ext.lowercased() {
        case "pdf":
            return "doc.richtext"
        case "txt", "md", "log", "json", "csv":
            return "doc.text"
        case "mp3", "wav", "m4a", "aac", "flac":
            return "music.note"
        case "mp4", "mov", "mkv":
            return "film"
        case "zip", "rar", "7z", "tar", "gz":
            return "archivebox"
        default:
            return "doc"
        }
    }
}

// MARK: - 辅助类型

private struct PreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActiveAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 用系统 QuickLook 预览已下载文件（图片/文档等）。
private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.navigationItem.title = url.lastPathComponent
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "完成",
            style: .done,
            target: context.coordinator,
            action: #selector(QuickLookPreview.Coordinator.close)
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