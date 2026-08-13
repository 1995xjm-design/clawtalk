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

    /// 单文件上传大小上限（与电脑端服务端一致）：50MB。
    static let maxUploadBytes: Int64 = 50 * 1024 * 1024

    // 状态
    var serverState: ServerState = .checking
    var remoteFiles: [RemoteFile] = []
    var downloadedFiles: [LocalFile] = []
    var isLoadingFiles = false
    var isSendingStartCommand = false
    var waitingForServer = false
    var downloadingFileName: String?
    var isUploading = false
    var uploadProgress: Double?
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

    // MARK: - 上传（手机 → 电脑）

    /// 上传失败分类：用于给用户区分「电脑端文件服务未启动」与「网络不通」。
    enum UploadFailureKind: Equatable {
        /// 电脑端文件服务未启动/未监听/返回异常（HTTP 层或连接被拒）
        case serverNotStarted(String)
        /// 网络不通（超时/断网/无法解析主机）
        case networkUnreachable(String)
        /// 文件超过大小上限
        case fileTooLarge
        /// 无法读取文件
        case invalidFile
        /// 其他错误
        case other(String)

        /// 面向用户的明确文案。
        var friendlyText: String {
            switch self {
            case .serverNotStarted(let detail):
                return "电脑端文件服务未启动或异常（\(detail)）：请先在电脑端启动文件服务（clawtalk_files_server.py），再重试。"
            case .networkUnreachable(let detail):
                return "网络不通（\(detail)）：请检查手机与电脑是否在同一网络（或已连上 Tailscale）后重试。"
            case .fileTooLarge:
                return "文件超过 50MB 上限，无法上传。"
            case .invalidFile:
                return "无法读取文件内容，请重试。"
            case .other(let detail):
                return "上传失败：\(detail)"
            }
        }
    }

    /// 最近一次上传失败分类（供自动日志上报等调用方读取明确提示）。
    private(set) var lastUploadFailure: UploadFailureKind?

    /// 上传本地文件到电脑端 inbound 目录（POST /upload，multipart/form-data）。
    /// 失败自动重试：最多重试 `maxRetries` 次（间隔 3 秒、6 秒），重试仍失败时给出
    /// 区分「文件服务未启动」与「网络不通」的明确文案。
    /// - Parameters:
    ///   - fileURL: 本地文件 URL（App 沙盒 / 临时目录内）
    ///   - suggestedName: 服务端保存的文件名（默认取 fileURL 文件名）
    ///   - maxRetries: 失败后的重试次数（默认 2，即最多共 3 次尝试）
    @discardableResult
    func uploadFile(fileURL: URL, suggestedName: String? = nil, maxRetries: Int = 2) async -> Bool {
        guard let uploadURL = URL(string: serverBaseURL + "/upload") else {
            let kind = UploadFailureKind.other("上传地址无效，请先配置网关地址。")
            lastUploadFailure = kind
            errorMessage = kind.friendlyText
            return false
        }

        let name = suggestedName ?? fileURL.lastPathComponent
        let boundary = "----ClawTalkBoundary" + UUID().uuidString
        guard let body = Self.makeMultipartBody(fileURL: fileURL, fileName: name, boundary: boundary) else {
            let kind = UploadFailureKind.invalidFile
            lastUploadFailure = kind
            errorMessage = kind.friendlyText
            return false
        }
        guard body.count <= Self.maxUploadBytes else {
            let kind = UploadFailureKind.fileTooLarge
            lastUploadFailure = kind
            errorMessage = kind.friendlyText
            return false
        }

        // 重试间隔（秒）：第 1 次失败后等 3 秒，第 2 次失败后等 6 秒。
        let retryDelays: [Double] = [3, 6]

        isUploading = true
        uploadProgress = 0
        errorMessage = nil
        lastUploadFailure = nil
        defer {
            isUploading = false
            uploadProgress = nil
        }

        let attempts = max(0, maxRetries) + 1
        for attempt in 1...attempts {
            let (ok, failure) = await performUploadAttempt(
                uploadURL: uploadURL,
                body: body,
                boundary: boundary
            )
            if ok {
                lastUploadFailure = nil
                return true
            }
            lastUploadFailure = failure
            if attempt < attempts {
                let delay = retryDelays[min(attempt - 1, retryDelays.count - 1)]
                LogCollector.record(module: "文件传输", "上传失败（第 \(attempt)/\(attempts) 次），\(Int(delay)) 秒后重试：\(failure?.friendlyText ?? "")")
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        let kind = lastUploadFailure ?? .other("未知错误")
        if attempts > 1 {
            errorMessage = "上传失败（已重试 \(attempts - 1) 次）：\(kind.friendlyText)"
        } else {
            errorMessage = kind.friendlyText
        }
        return false
    }

    /// 单次上传尝试：返回是否成功与失败分类。
    private func performUploadAttempt(
        uploadURL: URL,
        body: Data,
        boundary: String
    ) async -> (Bool, UploadFailureKind?) {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let delegate = UploadTaskDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        delegate.progressHandler = { [weak self] progress in
            self?.uploadProgress = progress
        }

        do {
            let (_, response): (Data, HTTPURLResponse) = try await withCheckedThrowingContinuation { continuation in
                delegate.prepare(continuation)
                let task = session.uploadTask(with: request, from: body)
                task.resume()
            }
            session.finishTasksAndInvalidate()
            guard (200...299).contains(response.statusCode) else {
                let kind = UploadFailureKind.serverNotStarted("HTTP \(response.statusCode)")
                return (false, kind)
            }
            return (true, nil)
        } catch {
            session.invalidateAndCancel()
            return (false, Self.classifyUploadError(error))
        }
    }

    /// 把上传错误归类为「服务未启动」或「网络不通」，给用户明确提示。
    private static func classifyUploadError(_ error: Error) -> UploadFailureKind {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return .networkUnreachable("未连接互联网")
            case .timedOut:
                return .networkUnreachable("请求超时")
            case .networkConnectionLost:
                return .networkUnreachable("连接中断")
            case .cannotFindHost, .dnsLookupFailed:
                return .networkUnreachable("无法访问主机（DNS）")
            case .cannotConnectToHost:
                return .serverNotStarted("连接被拒绝（端口 8899 未监听）")
            default:
                return .other(AppErrorText.localized(urlError.localizedDescription))
            }
        }
        return .other(AppErrorText.localized(error.localizedDescription))
    }
    private static func makeMultipartBody(fileURL: URL, fileName: String, boundary: String) -> Data? {
        guard let fileData = try? Data(contentsOf: fileURL) else { return nil }
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")
        return body
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

// MARK: - 上传进度代理

/// URLSession 上传代理：报告上传进度，并把完成结果桥接回 async/await。
private final class UploadTaskDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    var progressHandler: ((Double) -> Void)?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var receivedData = Data()

    func prepare(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let progress = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        let handler = progressHandler
        Task { @MainActor in
            handler?(progress)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let response = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        continuation.resume(returning: (receivedData, response))
    }
}