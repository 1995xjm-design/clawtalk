import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// 文件传输助手（频道版）：电脑端 OpenClaw 成果文件（media/outbound）以「聊天卡片」形式逐条展示。
/// 复用 FileTransferViewModel 的服务检测、一键启动、下载、存相册、QuickLook、分享、删除逻辑。
/// - embeddedInNavigation = true：从「工具」页进入，使用系统导航栏；
/// - embeddedInNavigation = false：从频道列表进入，使用与聊天页一致的「返回频道」自定义导航栏。
struct FileTransferChannelView: View {
    @State private var viewModel: FileTransferViewModel

    let settings: SettingsStore
    var embeddedInNavigation = false
    var onBack: (() -> Void)?

    @State private var showManualInstructions = false
    @State private var showImageActionSheet = false
    @State private var pendingImageURL: URL?
    @State private var previewItem: PreviewItem?
    @State private var activeAlert: ActiveAlert?
    @State private var showDownloadConfirm = false
    @State private var pendingDownloadFile: FileTransferViewModel.RemoteFile?
    @State private var showFileSourceDialog = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var uploadResults: [UploadResultItem] = []
    @State private var uploadBatchTotal = 0

    init(settings: SettingsStore, embeddedInNavigation: Bool = false, onBack: (() -> Void)? = nil) {
        self.settings = settings
        self.embeddedInNavigation = embeddedInNavigation
        self.onBack = onBack
        _viewModel = State(initialValue: FileTransferViewModel(settings: settings))
    }

    var body: some View {
        Group {
            if embeddedInNavigation {
                content
            } else {
                VStack(spacing: 0) {
                    navBar
                    Divider().opacity(0.3)
                    content
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("文件传输助手")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 自定义导航栏（频道模式）

    private var navBar: some View {
        ZStack {
            HStack(spacing: 6) {
                Text("文件传输助手")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            HStack {
                Button(action: { onBack?() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.title3)
                        Text("频道")
                            .font(.body)
                    }
                    .foregroundStyle(.openClawRed)
                    .contentShape(Rectangle())
                    .padding(.vertical, 6)
                    .padding(.trailing, 4)
                }

                Spacer()

                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.title)
                        .foregroundStyle(.openClawRed)
                        .contentShape(Rectangle())
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("刷新")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 内容区（检测 / 引导 / 聊天文件列表）

    private var content: some View {
        Group {
            switch viewModel.serverState {
            case .checking:
                ProgressView("正在检测电脑端文件服务…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unreachable:
                guideView
            case .reachable:
                chatFileList
            }
        }
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
        .confirmationDialog(
            "是否下载？",
            isPresented: $showDownloadConfirm,
            titleVisibility: .visible,
            presenting: pendingDownloadFile
        ) { file in
            Button("下载") { startDownload(file) }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "发送文件到电脑",
            isPresented: $showFileSourceDialog,
            titleVisibility: .visible
        ) {
            Button("从相册选择") { showPhotoPicker = true }
            Button("从文件选择") { showFileImporter = true }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 0, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await uploadPickedFiles(urls: urls) }
            case .failure(let error):
                showHint("选择文件失败：\(error.localizedDescription)")
            }
        }
        .onChange(of: photoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                var urls: [URL] = []
                var tempURLs: [URL] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "bin"
                        let name = "photo-\(UUID().uuidString.prefix(8)).\(ext)"
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                        do {
                            try data.write(to: tempURL)
                        } catch {
                            continue
                        }
                        urls.append(tempURL)
                        tempURLs.append(tempURL)
                    } else if let fileURL = try? await item.loadTransferable(type: URL.self) {
                        urls.append(fileURL)
                    }
                }
                photoItems = []
                await uploadPickedFiles(urls: urls)
                for url in tempURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - 服务未启动引导

    private var guideView: some View {
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
    // MARK: - 聊天式文件列表

    /// 发送文件到电脑（相册 / 文件选择，带上传进度）。
    private var uploadBar: some View {
        VStack(spacing: 8) {
            Button {
                showFileSourceDialog = true
            } label: {
                Label(viewModel.isUploading ? "正在上传…" : "发送文件到电脑", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.openClawRed)
            .disabled(viewModel.isUploading)

            if viewModel.isUploading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(uploadBatchTotal > 0 ? "正在批量上传（\(uploadResults.count)/\(uploadBatchTotal)）…" : "正在上传…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = viewModel.uploadProgress {
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                    Text("当前文件已上传 \(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !uploadResults.isEmpty {
                VStack(spacing: 6) {
                    ForEach(uploadResults) { item in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                if let message = item.message {
                                    Text(message)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 4)
                            Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(item.success ? .green : .red)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var chatFileList: some View {
        List {
            Section {
                uploadBar
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowBackground(Color.clear)
            }

            Section {
                HStack {
                    Spacer()
                    Text("电脑端 OpenClaw 成果文件（media/outbound）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
            }

            if viewModel.remoteFiles.isEmpty {
                Section {
                    if viewModel.isLoadingFiles {
                        ProgressView("正在加载文件列表…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                            .padding(.bottom, 60)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.system(size: 44))
                                .foregroundStyle(.tertiary)
                            Text("电脑端暂无文件")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("下拉刷新，或点右上角刷新按钮")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                        .padding(.bottom, 60)
                    }
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.remoteFiles) { file in
                        remoteFileCard(file)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if let local = viewModel.localFile(named: file.name) {
                                    Button(role: .destructive) {
                                        viewModel.deleteDownloadedFile(local)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                } else {
                                    Button {
                                        startDownload(file)
                                    } label: {
                                        Label("下载", systemImage: "arrow.down")
                                    }
                                    .tint(.openClawRed)
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                if let local = viewModel.localFile(named: file.name) {
                                    ShareLink(item: local.url) {
                                        Label("分享", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.green)
                                }
                            }
                    }
                }
                .listRowBackground(Color.clear)

                if !orphanLocalFiles.isEmpty {
                    Section {
                        Text("已下载（电脑端已删除）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                        ForEach(orphanLocalFiles) { file in
                            localFileCard(file)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(Color.clear)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        viewModel.deleteDownloadedFile(file)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    ShareLink(item: file.url) {
                                        Label("分享", systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.green)
                                }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
    }

    /// 本地已下载、但电脑端列表里已不存在的文件（补在聊天列表末尾，仍可打开/分享/删除）。
    private var orphanLocalFiles: [FileTransferViewModel.LocalFile] {
        let remoteNames = Set(viewModel.remoteFiles.map(\.name))
        return viewModel.downloadedFiles.filter { !remoteNames.contains($0.name) }
    }

    // MARK: - 聊天卡片

    private func remoteFileCard(_ file: FileTransferViewModel.RemoteFile) -> some View {
        let local = viewModel.localFile(named: file.name)
        return HStack(spacing: 12) {
            // 卡片主体：未下载 → 弹「是否下载？」确认框；已下载 → 打开预览
            Button {
                handleFileTap(file)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: iconName(forExtension: file.ext))
                        .font(.title2)
                        .foregroundStyle(.openClawRed)
                        .frame(width: 40, height: 40)
                        .background(Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(.body)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Text("\(FileTransferViewModel.formatBytes(file.size)) · \(FileTransferViewModel.formatTime(millis: file.mtime))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if local != nil {
                            Label("已下载", systemImage: "checkmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.downloadingFileName != nil && viewModel.downloadingFileName != file.name)

            // 右侧按钮：未下载 → 直接下载；已下载 → 分享
            if viewModel.downloadingFileName == file.name {
                ProgressView()
            } else if let local {
                ShareLink(item: local.url) {
                    Image(systemName: "arrow.up.forward.circle")
                        .font(.title3)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    startDownload(file)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.openClawRed)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.downloadingFileName != nil)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu {
            if let local = local {
                Button {
                    previewItem = PreviewItem(url: local.url)
                } label: {
                    Label("打开", systemImage: "doc")
                }
                if FileTransferViewModel.isImage(ext: file.ext) {
                    Button {
                        Task {
                            if await viewModel.saveImageToPhotoLibrary(url: local.url) {
                                showHint("已保存到相册。")
                            }
                        }
                    } label: {
                        Label("保存到相册", systemImage: "photo")
                    }
                }
                ShareLink(item: local.url) {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) {
                    viewModel.deleteDownloadedFile(local)
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
    }

    private func localFileCard(_ file: FileTransferViewModel.LocalFile) -> some View {
        Button {
            previewItem = PreviewItem(url: file.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: iconName(forExtension: file.url.pathExtension))
                    .font(.title2)
                    .foregroundStyle(.openClawRed)
                    .frame(width: 40, height: 40)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text("\(FileTransferViewModel.formatBytes(file.size)) · \(FileTransferViewModel.formatDate(file.modifiedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.forward.circle")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if FileTransferViewModel.isImage(ext: file.url.pathExtension) {
                Button {
                    Task {
                        if await viewModel.saveImageToPhotoLibrary(url: file.url) {
                            showHint("已保存到相册。")
                        }
                    }
                } label: {
                    Label("保存到相册", systemImage: "photo")
                }
            }
            ShareLink(item: file.url) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                viewModel.deleteDownloadedFile(file)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    // MARK: - 交互

    /// 点击卡片：已下载则打开预览，未下载则弹出「是否下载？」确认框；图片下载后询问保存到相册。
    private func handleFileTap(_ file: FileTransferViewModel.RemoteFile) {
        if let local = viewModel.localFile(named: file.name) {
            previewItem = PreviewItem(url: local.url)
        } else {
            pendingDownloadFile = file
            showDownloadConfirm = true
        }
    }

    /// 多文件队列上传：逐个上传，逐文件记录结果并汇总成功/失败数量。
    private func uploadPickedFiles(urls: [URL]) async {
        var successCount = 0
        var failedCount = 0
        uploadResults = []
        uploadBatchTotal = urls.count
        for url in urls {
            let name = url.lastPathComponent
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let ok = await viewModel.uploadFile(fileURL: url, suggestedName: name)
            if ok {
                successCount += 1
                uploadResults.append(UploadResultItem(name: name, success: true, message: nil))
            } else {
                failedCount += 1
                uploadResults.append(UploadResultItem(name: name, success: false, message: viewModel.lastUploadFailure?.friendlyText))
            }
        }
        if successCount > 0 {
            showHint("已发送 \(successCount) 个文件到电脑\(failedCount > 0 ? "，\(failedCount) 个失败" : "")")
        } else if failedCount > 0 {
            showHint("发送失败：\(failedCount) 个文件")
        }
    }
    /// 上传用户选择的文件到电脑端 inbound（成功后提示）。
    private func uploadPickedFile(url: URL, suggestedName: String) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let ok = await viewModel.uploadFile(fileURL: url, suggestedName: suggestedName)
        if ok {
            showHint("已发送到电脑 inbound（\(suggestedName)）")
        }
    }

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

/// 单个文件上传结果（供上传区逐条展示成功/失败）。
private struct UploadResultItem: Identifiable {
    let id = UUID()
    let name: String
    let success: Bool
    let message: String?
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