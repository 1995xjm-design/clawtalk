import Foundation
import Observation
import Photos
import UIKit

/// 文件传输助手：电脑端 OpenClaw 成果文件（media/outbound）的列表、下载与本地管理。
/// 文件服务接口（电脑端 clawtalk_files_server.py，监听 8899）：
///   GET /api/status  -> {"ok": true, "root": "...", "port": 8899}
///   GET /api/files   -> {"files": [{"name","size","mtime","ext"}]}（按 mtime 倒序）
///   GET /download?path=文件名 -> 文件下载
@Observable
@MainActor
final class FileTransferViewModel {
    enum ServerState: Equatable {
        case checking
        case reachable
        case unreachable
    }

    struct RemoteFile: Identifiable, Decodable, Equatable {
        let name: String
        let size: Int64
        let mtime: Int64
        let ext: String

        var id: String { name }
    }

    struct LocalFile: Identifiable, Equatable {
        let url: URL
        let name: String
        let size: Int64
        let modifiedAt: Date

        var id: String { name }
    }

    private struct StatusResponse: Decodable {
        let ok: Bool?
    }

    private struct FileListResponse: Decodable {
        let files: [RemoteFile]?
    }

    /// 文件服务固定端口（与网关同 IP）
    static let filesPort = 8899

    private static let imageExtSet: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]

    // 状态
    var serverState: ServerState = .checking
    var remoteFiles: [RemoteFile] = []
    var downloadedFiles: [LocalFile] = []
    var isLoadingFiles = false
    var isSendingStartCommand = false
    var waitingForServer = false
    var downloadingFileName: String?
    var errorMessage: String? {
        didSet { if let errorMessage { LogCollector.record(module: "文件传输", errorMessage) } }
    }

    private let settings: SettingsStore
    private let filesDirectory: URL

    init(settings: SettingsStore) {
        self.settings = settings
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.filesDirectory = documents.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.filesDirectory, withIntermediateDirectories: true)
    }

    /// 文件服务地址：优先取设置里的 fileServerURL，留空则从网关地址推断（同主机、端口 8899）。
    var serverBaseURL: String {
        let custom = settings.settings.fileServerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !custom.isEmpty {
            return custom
        }

        let gateway = settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: gateway),
              let host = components.host, !host.isEmpty else { return "" }
        // 文件服务是电脑端明文 HTTP，固定用 http + 同主机 + 8899
        components.scheme = "http"
        components.port = Self.filesPort
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? ""
    }

    /// 一键启动是否可用（需要已配置网关地址和令牌）
    var canSendStartCommand: Bool {
        !settings.settings.gatewayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.gatewayToken.isEmpty
    }

    // MARK: - 服务可达性 / 文件列表

    /// 检测文件服务是否可达（GET /api/status），可达后自动加载文件列表。
    func checkServer() async {
        serverState = .checking
        errorMessage = nil

        let base = serverBaseURL
        guard !base.isEmpty, let url = URL(string: base + "/api/status") else {
            serverState = .unreachable
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                serverState = .unreachable
                return
            }
            let status = try? JSONDecoder().decode(StatusResponse.self, from: data)
            if status?.ok == true {
                serverState = .reachable
                await loadRemoteFiles()
            } else {
                serverState = .unreachable
            }
        } catch {
            serverState = .unreachable
        }
    }

    /// 加载电脑端文件列表（GET /api/files，服务端已按 mtime 倒序）。
    func loadRemoteFiles() async {
        guard !isLoadingFiles else { return }
        isLoadingFiles = true
        errorMessage = nil
        defer { isLoadingFiles = false }

        guard let url = URL(string: serverBaseURL + "/api/files") else {
            serverState = .unreachable
            return
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(FileListResponse.self, from: data)
            remoteFiles = decoded.files ?? []
            serverState = .reachable
        } catch {
            errorMessage = "加载文件列表失败：\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    /// 下拉刷新：可达时刷新列表，不可达时重新检测。
    func refresh() async {
        reloadDownloadedFiles()
        if serverState == .reachable {
            await loadRemoteFiles()
        } else {
            await checkServer()
        }
    }

    // MARK: - 一键启动

    /// 一键启动：向「文件传输」频道发送启动指令，随后轮询等待服务可达。
    func sendStartCommand() async {
        guard !isSendingStartCommand else { return }
        isSendingStartCommand = true
        errorMessage = nil
        defer { isSendingStartCommand = false }

        let gatewayURL = settings.settings.gatewayURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !gatewayURL.isEmpty else {
            errorMessage = "未配置网关地址，无法发送启动指令。"
            return
        }
        guard !settings.gatewayToken.isEmpty else {
            errorMessage = "未配置网关令牌，无法发送启动指令。"
            return
        }

        InstructionChannels.ensureChannel(
            name: "文件传输",
            systemEmoji: "📁",
            sessionKey: InstructionChannels.fileTransfer
        )

        let instruction = """
        请帮我启动「ClawTalk 文件传输助手」电脑端文件服务：
        1. 找到文件服务脚本：C:\\Users\\Youhome\\Documents\\Codex\\2026-08-06\\v4-pro-v4-flash\\fusion-backend\\clawtalk_files_server.py（如不存在请先检查路径并告知我）。
        2. 在本机运行 Python 启动该脚本（默认监听 0.0.0.0:8899，手机与电脑同一网络或 Tailscale 即可访问）：
           python "C:\\Users\\Youhome\\Documents\\Codex\\2026-08-06\\v4-pro-v4-flash\\fusion-backend\\clawtalk_files_server.py"
        3. 确认服务已启动：本机请求 http://127.0.0.1:8899/api/status 应返回 {"ok": true}。
        4. 完成后回复「文件服务已启动」；如果启动失败，请告诉我具体原因。
        """

        do {
            _ = try await OpenClawClient().chat(
                messages: [Message(role: .user, content: instruction)],
                gatewayURL: gatewayURL,
                token: settings.gatewayToken,
                sessionKey: InstructionChannels.fileTransfer
            )
            waitingForServer = true
            await waitForServerUp()
        } catch {
            errorMessage = "启动指令发送失败：\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    /// 发送指令后轮询 /api/status，最多约 60 秒。
    private func waitForServerUp() async {
        var attempts = 0
        while attempts < 30, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            attempts += 1
            if await isServerReachable() {
                waitingForServer = false
                serverState = .reachable
                await loadRemoteFiles()
                return
            }
        }
        waitingForServer = false
        if serverState != .reachable {
            errorMessage = "尚未检测到文件服务启动，请确认电脑端已执行指令，或参考「手动说明」。"
        }
    }

    private func isServerReachable() async -> Bool {
        guard let url = URL(string: serverBaseURL + "/api/status") else { return false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
            return (try? JSONDecoder().decode(StatusResponse.self, from: data))?.ok == true
        } catch {
            return false
        }
    }

    // MARK: - 下载 / 保存

    /// 下载电脑端文件到 App 沙盒 Documents/files/，返回下载后的本地文件 URL。
    @discardableResult
    func downloadFile(_ file: RemoteFile) async -> URL? {
        guard let encoded = file.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "\(serverBaseURL)/download?path=\(encoded)") else {
            errorMessage = "下载地址无效。"
            return nil
        }

        downloadingFileName = file.name
        errorMessage = nil
        defer { downloadingFileName = nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let destination = uniqueDestinationURL(for: file.name)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            reloadDownloadedFiles()
            return destination
        } catch {
            errorMessage = "下载失败：\(AppErrorText.localized(error.localizedDescription))"
            return nil
        }
    }

    /// 同名文件已存在时追加序号，避免覆盖。
    private func uniqueDestinationURL(for name: String) -> URL {
        let base = filesDirectory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }

        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidateName = ext.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(ext)"
            let candidate = filesDirectory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    /// 把已下载的图片保存到相册（PHPhotoLibrary addOnly，不申请读库权限）。
    func saveImageToPhotoLibrary(url: URL) async -> Bool {
        guard let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            errorMessage = "无法读取图片文件，保存到相册失败。"
            return false
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            errorMessage = "没有相册写入权限，请到系统设置中允许 ClawTalk 添加照片。"
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
            return true
        } catch {
            errorMessage = "保存到相册失败：\(AppErrorText.localized(error.localizedDescription))"
            return false
        }
    }

    // MARK: - 本地已下载文件

    func reloadDownloadedFiles() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: filesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )) ?? []

        let items = contents.compactMap { url -> LocalFile? in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isDirectory != true,
                  let size = values.fileSize else { return nil }
            return LocalFile(
                url: url,
                name: url.lastPathComponent,
                size: Int64(size),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        downloadedFiles = items.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func deleteDownloadedFile(_ file: LocalFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
            reloadDownloadedFiles()
        } catch {
            errorMessage = "删除文件失败：\(AppErrorText.localized(error.localizedDescription))"
        }
    }

    /// 按文件名查找本地已下载文件（用于聊天卡片标记「已下载」状态）。
    func localFile(named name: String) -> LocalFile? {
        downloadedFiles.first { $0.name == name }
    }

    // MARK: - 格式化辅助

    static func isImage(ext: String) -> Bool {
        imageExtSet.contains(ext.lowercased())
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func formatTime(millis: Int64) -> String {
        fileDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    static func formatDate(_ date: Date) -> String {
        fileDateFormatter.string(from: date)
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}