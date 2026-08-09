import Foundation
import Observation

// MARK: - 本地文件路径（顶层枚举，避免 actor 隔离限制，供下载/推理后台线程直接使用）

/// Kokoro 模型文件在沙盒中的固定路径（Documents/Models/Kokoro/）。
enum KokoroModelPaths {
    static let directory = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Models/Kokoro", isDirectory: true)

    /// ONNX 主模型（v1.1-zh，fp32，约 328MB）
    static var modelFile: URL {
        directory.appendingPathComponent("kokoro-v1.1-zh.onnx")
    }

    /// 音色包（npz 归档，内含 zf_001 / zm_010 等音色，约 51MB）
    static var voicesFile: URL {
        directory.appendingPathComponent("voices-v1.1-zh.bin")
    }

    /// 两个模型文件是否都已就位（供推理后台线程直接检测，不依赖 UserDefaults）
    static var filesExist: Bool {
        FileManager.default.fileExists(atPath: modelFile.path)
            && FileManager.default.fileExists(atPath: voicesFile.path)
    }
}

/// Kokoro 音色包：一个音色的完整 style 序列（v1.1-zh 为 510 行 × 256 列 float32）。
/// 推理时按音素串长度取其中一行作为 style 输入（与 kokoro 的 pack[len(ps)-1] 一致）。
struct KokoroVoicePack {
    let rows: Int
    let columns: Int
    let samples: [Float]

    /// 取第 index 行的 256 维 style 向量，越界自动 clamp。
    func style(at index: Int) throws -> [Float] {
        guard columns > 0, samples.count >= rows * columns else {
            throw KokoroModelError.invalidVoicePack("音色包数据不完整")
        }
        let row = min(max(index, 0), rows - 1)
        let start = row * columns
        return Array(samples[start..<(start + columns)])
    }
}

// MARK: - 错误类型

enum KokoroModelError: LocalizedError {
    case voiceNotFound(String)
    case fileMissing(String)
    case unsupportedArchive(String)
    case unsupportedCompression(String)
    case invalidNumpy(String)
    case invalidVoicePack(String)
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .voiceNotFound(let name):
            return "音色「\(name)」不存在于音色包中"
        case .fileMissing(let path):
            return "模型文件缺失：\(path)"
        case .unsupportedArchive(let detail):
            return "音色包格式不支持：\(detail)"
        case .unsupportedCompression(let detail):
            return "音色包使用了不支持的压缩：\(detail)"
        case .invalidNumpy(let detail):
            return "音色包内数组格式错误：\(detail)"
        case .invalidVoicePack(let detail):
            return "音色包数据错误：\(detail)"
        case .downloadFailed(let detail):
            return "模型下载失败：\(detail)"
        }
    }
}

// MARK: - npz / npy 解析（仅支持 ZIP STORED 的 numpy 归档）

/// 极简 numpy `.npz`（zip）→ `.npy` 解析器。
/// 背景：kokoro-onnx 的 voices-v1.1-zh.bin 是 `np.savez` 产物（ZIP_STORED、C 顺序、<f4）。
/// 本实现只支持 STORED 条目；若未来换用 savez_compressed（DEFLATE）需引入 zlib 解码。
private enum KokoroVoiceArchive {
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralDirectorySignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let numpyMagic = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]) // "\x93NUMPY"

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset])
            | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[data.startIndex + offset])
            | (UInt32(data[data.startIndex + offset + 1]) << 8)
            | (UInt32(data[data.startIndex + offset + 2]) << 16)
            | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    /// 在 zip 数据中定位 EOCD，返回（中央目录偏移、中央目录字节数）。
    private static func locateCentralDirectory(in data: Data) throws -> (offset: Int, size: Int) {
        guard data.count >= 22 else {
            throw KokoroModelError.unsupportedArchive("文件过小，不是有效的 zip/npz")
        }
        let searchStart = max(0, data.count - 65_557)
        var cursor = data.count - 22
        while cursor >= searchStart {
            if readUInt32(data, cursor) == endOfCentralDirectorySignature {
                let totalEntries = Int(readUInt16(data, cursor + 10))
                let size = Int(readUInt32(data, cursor + 12))
                let offset = Int(readUInt32(data, cursor + 16))
                guard totalEntries > 0, offset >= 0, offset + size <= data.count else {
                    throw KokoroModelError.unsupportedArchive("zip 中央目录损坏")
                }
                return (offset, size)
            }
            cursor -= 1
        }
        throw KokoroModelError.unsupportedArchive("未找到 zip 中央目录")
    }

    /// 返回所有条目名（形如 "zf_001.npy"）。
    static func entryNames(in data: Data) throws -> [String] {
        let (cdOffset, cdSize) = try locateCentralDirectory(in: data)
        var names: [String] = []
        var cursor = cdOffset
        let end = cdOffset + cdSize
        while cursor + 46 <= end {
            guard readUInt32(data, cursor) == centralDirectorySignature else { break }
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let nameStart = cursor + 46
            if nameLength > 0, nameStart + nameLength <= data.count,
               let name = String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8) {
                names.append(name)
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return names
    }

    /// 读取指定条目（仅支持 STORED 压缩），返回该条目的原始字节。
    static func entryData(named entryName: String, in data: Data) throws -> Data? {
        let (cdOffset, cdSize) = try locateCentralDirectory(in: data)
        var cursor = cdOffset
        let end = cdOffset + cdSize
        while cursor + 46 <= end {
            guard readUInt32(data, cursor) == centralDirectorySignature else { break }
            let method = Int(readUInt16(data, cursor + 10))
            let compressedSize = Int(readUInt32(data, cursor + 20))
            let nameLength = Int(readUInt16(data, cursor + 28))
            let extraLength = Int(readUInt16(data, cursor + 30))
            let commentLength = Int(readUInt16(data, cursor + 32))
            let localHeaderOffset = Int(readUInt32(data, cursor + 42))
            let nameStart = cursor + 46
            let name = nameLength > 0 && nameStart + nameLength <= data.count
                ? String(data: data.subdata(in: nameStart..<(nameStart + nameLength)), encoding: .utf8)
                : nil

            if name == entryName {
                guard method == 0 else {
                    throw KokoroModelError.unsupportedCompression(
                        "条目 \(entryName) 压缩方式=\(method)（仅支持 STORED，np.savez 默认产物）"
                    )
                }
                // 本地文件头：签名(4)+版本(2)+标志(2)+压缩方式(2)+时间(2)+日期(2)
                // +CRC(4)+压缩大小(4)+原始大小(4)+文件名长(2)+扩展长(2)+名称+扩展+数据
                let localOffset = localHeaderOffset
                guard localOffset + 30 <= data.count,
                      readUInt32(data, localOffset) == localFileHeaderSignature else {
                    throw KokoroModelError.unsupportedArchive("本地文件头损坏")
                }
                let localNameLength = Int(readUInt16(data, localOffset + 26))
                let localExtraLength = Int(readUInt16(data, localOffset + 28))
                let dataStart = localOffset + 30 + localNameLength + localExtraLength
                let dataEnd = dataStart + compressedSize
                guard dataStart >= 0, dataEnd <= data.count else {
                    throw KokoroModelError.unsupportedArchive("条目数据越界")
                }
                return data.subdata(in: dataStart..<dataEnd)
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return nil
    }

    /// 解析单个 .npy（<f4、C 顺序）为 Float 数组。
    static func parseFloat32Numpy(_ bytes: Data) throws -> ([Float], shape: [Int]) {
        guard bytes.count > 10, bytes.prefix(6) == numpyMagic else {
            throw KokoroModelError.invalidNumpy("缺少 NUMPY 魔数")
        }
        let major = bytes[bytes.startIndex + 6]
        var headerLength: Int
        var headerStart: Int
        switch major {
        case 1:
            headerLength = Int(readUInt16(bytes, 8))
            headerStart = 10
        case 2, 3:
            headerLength = Int(readUInt32(bytes, 8))
            headerStart = 12
        default:
            throw KokoroModelError.invalidNumpy("不支持的 npy 版本 \(major)")
        }
        guard headerStart + headerLength <= bytes.count else {
            throw KokoroModelError.invalidNumpy("头部长度越界")
        }
        guard let header = String(data: bytes.subdata(in: headerStart..<(headerStart + headerLength)), encoding: .ascii) else {
            throw KokoroModelError.invalidNumpy("头部不是 ASCII")
        }

        // descr：只接受小端/原生 float32
        guard let descrRange = header.range(of: #"'descr':\s*'([^']+)'"#, options: .regularExpression) else {
            throw KokoroModelError.invalidNumpy("缺少 descr")
        }
        let descr = String(header[descrRange])
        guard descr.contains("<f4") || descr.contains("|f4") || descr.contains("=f4") else {
            throw KokoroModelError.invalidNumpy("descr=\(descr)，仅支持 float32")
        }
        // fortran_order：只接受 C 顺序
        if header.range(of: #"fortran_order':\s*True"#, options: .regularExpression) != nil {
            throw KokoroModelError.invalidNumpy("fortran_order=True 暂不支持")
        }
        // shape
        guard let shapeRange = header.range(of: #"shape':\s*\(([^)]*)\)"#, options: .regularExpression) else {
            throw KokoroModelError.invalidNumpy("缺少 shape")
        }
        let shapeBody = header[shapeRange]
            .replacingOccurrences(of: #"shape':\s*\("#, with: "", options: .regularExpression)
            .replacingOccurrences(of: ")", with: "")
        let shape = shapeBody
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard shape.allSatisfy({ $0 > 0 }) else {
            throw KokoroModelError.invalidNumpy("shape 非法：\(shapeBody)")
        }

        let dataStart = headerStart + headerLength
        let sampleCount = shape.reduce(1, *)
        let byteCount = sampleCount * MemoryLayout<Float>.size
        guard dataStart + byteCount <= bytes.count else {
            throw KokoroModelError.invalidNumpy("数据长度不足")
        }
        let payload = bytes.subdata(in: dataStart..<(dataStart + byteCount))
        let floats: [Float] = payload.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: ptr.baseAddress, count: sampleCount))
        }
        return (floats, shape)
    }

    /// 从 npz 数据中提取指定音色的 pack。
    static func pack(from data: Data, name: String) throws -> KokoroVoicePack {
        let entryName = name.hasSuffix(".npy") ? name : name + ".npy"
        guard let entry = try entryData(named: entryName, in: data) else {
            throw KokoroModelError.voiceNotFound(name)
        }
        let (samples, shape) = try parseFloat32Numpy(entry)
        // 音色 npy 可能是 [frames, dim]（如 [510, 256]）或带单例维的 [frames, 1, dim]
        // （如 [510, 1, 256]）：过滤掉单例维后按 [frames, dim] 处理。
        let dims = shape.filter { $0 > 1 }
        let rows: Int
        let columns: Int
        if dims.count <= 1 {
            rows = dims.isEmpty ? 0 : 1
            columns = dims.last ?? 0
        } else {
            rows = dims[0]
            columns = dims.last ?? dims[0]
        }
        guard rows > 0, columns > 0, samples.count == rows * columns else {
            throw KokoroModelError.invalidVoicePack("音色 \(name) 形状非法：\(shape)")
        }
        return KokoroVoicePack(rows: rows, columns: columns, samples: samples)
    }
}

// MARK: - 顶层辅助函数（非隔离，供 KokoroTTSService 后台推理线程直接调用）

/// 读取指定音色的 style pack（如 "zf_001"）。
func KokoroLoadVoicePack(named name: String) throws -> KokoroVoicePack {
    let url = KokoroModelPaths.voicesFile
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw KokoroModelError.fileMissing(url.path)
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return try KokoroVoiceArchive.pack(from: data, name: name)
}

/// 列出音色包内全部音色名（供设置页选择音色）。
func KokoroListVoices() throws -> [String] {
    let url = KokoroModelPaths.voicesFile
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let names = try KokoroVoiceArchive.entryNames(in: data)
    return names
        .filter { $0.hasSuffix(".npy") }
        .map { String($0.dropLast(4)) }
        .sorted()
}

// MARK: - 模型管理器

/// Kokoro-82M（v1.1-zh，82M 参数，Apache-2.0）本地神经 TTS 模型管理器。
///
/// 职责：
/// 1. 下载模型文件（ONNX 主模型 + 音色包），带进度，状态风格与 WhisperModelManager 一致；
/// 2. 管理 Documents/Models/Kokoro/ 下的文件（存在性检查）；
/// 3. 解析音色包 npz，供 KokoroTTSService 推理时取 style。
///
/// 模型文件来源（2026-08 实测确认，下载走 GitHub Releases 以绕过 HF 网络不稳定）：
/// - ONNX 主模型：thewh1teagle/kokoro-onnx releases/download/model-files-v1.1/kokoro-v1.1-zh.onnx（约 328MB）
/// - 音色包：      thewh1teagle/kokoro-onnx releases/download/model-files-v1.1/voices-v1.1-zh.bin（约 51MB，npz）
/// - HuggingFace 原始权重（PyTorch，iOS 不直接用）：https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh
/// - 多语言 v1.0 备选（如需英文等）：model-files-v1.0/kokoro-v1.0.onnx + voices-v1.0.bin
@Observable
@MainActor
final class KokoroModelManager {
    static let shared = KokoroModelManager()

    // MARK: 状态（与 WhisperModelManager 风格一致）

    var isDownloading = false
    var downloadProgress: Double = 0
    var isModelReady = false
    var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let downloadedKey = "kokoro_model_downloaded"

    // MARK: 下载地址（可配置常量；如需换源只改这里）

    enum Source {
        /// v1.1-zh 中文专用 ONNX 主模型（fp32）
        static let modelURLString =
            "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/kokoro-v1.1-zh.onnx"

        /// v1.1-zh 音色包（npz，含 zf_001…、zm_010… 等 100 个中文音色）
        static let voicesURLString =
            "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/voices-v1.1-zh.bin"

        /// 国内镜像前缀（依次尝试，原 GitHub 地址放最后兜底）
        static let mirrors: [String] = [
            "https://gh-proxy.com/",
            "https://mirror.ghproxy.com/",
            ""
        ]
    }

    // MARK: 本地文件路径

    var modelFileURL: URL { KokoroModelPaths.modelFile }
    var voicesFileURL: URL { KokoroModelPaths.voicesFile }

    /// 两个文件都在才算下载完成。
    var hasDownloadedModel: Bool {
        defaults.bool(forKey: downloadedKey)
            && FileManager.default.fileExists(atPath: modelFileURL.path)
            && FileManager.default.fileExists(atPath: voicesFileURL.path)
    }

    // MARK: - 下载 API（设置页调用入口）

    func downloadIfNeeded() async {
        guard !hasDownloadedModel else { return }
        await downloadModel()
    }

    /// 顺序下载模型与音色包（模型约占 85% 进度，音色包 15%）。
    func downloadModel() async {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil
        do {
            try FileManager.default.createDirectory(at: KokoroModelPaths.directory, withIntermediateDirectories: true)
            try await downloadFile(from: Source.modelURLString, to: KokoroModelPaths.modelFile, startProgress: 0.0, endProgress: 0.85)
            try await downloadFile(from: Source.voicesURLString, to: KokoroModelPaths.voicesFile, startProgress: 0.85, endProgress: 1.0)

            isModelReady = true
            isDownloading = false
            downloadProgress = 1.0
            defaults.set(true, forKey: downloadedKey)
        } catch {
            isDownloading = false
            errorMessage = "Kokoro 模型下载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 音色读取（供推理/设置页预览）

    /// 解析音色包，返回指定音色的 style pack（如 "zf_001"）。
    /// 注意：推理线程请直接调用顶层函数 KokoroLoadVoicePack(named:)，
    /// 本方法运行在主线程（@MainActor），适合设置页预览等 UI 场景。
    func loadVoicePack(name: String) throws -> KokoroVoicePack {
        try KokoroLoadVoicePack(named: name)
    }

    /// 列出音色包内全部音色名（供设置页选择音色）。
    func availableVoices() throws -> [String] {
        try KokoroListVoices()
    }

    // MARK: - 内部下载实现

    /// 用 URLSessionDownloadTask（delegate 回调进度）下载单个文件到目标路径。
    /// 进度映射到 [startProgress, endProgress] 区段；目标已存在时先删除再移动。
    private func downloadFile(from urlString: String, to destination: URL, startProgress: Double, endProgress: Double) async throws {
        var lastError: Error?
        for mirror in Source.mirrors {
            guard let url = URL(string: mirror + urlString) else { continue }
            do {
                let downloader = KokoroFileDownloader(url: url, destination: destination)
                downloader.onProgress = { [weak self] fraction in
                    Task { @MainActor in
                        self?.downloadProgress = startProgress + (endProgress - startProgress) * fraction
                    }
                }
                defer { downloader.invalidate() }
                _ = try await downloader.start()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? KokoroModelError.downloadFailed("所有下载源都失败：\(urlString)")
    }
}

/// 单文件下载器：URLSessionDownloadTask + 进度回调（与 WhisperKit 的 progressCallback 等价）。
private final class KokoroFileDownloader: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let destination: URL
    private lazy var session: URLSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?

    var onProgress: ((Double) -> Void)?

    init(url: URL, destination: URL) {
        self.url = url
        self.destination = destination
        super.init()
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.downloadTask(with: url)
            self.task = task
            task.resume()
        }
    }

    func invalidate() {
        task?.cancel()
        session.invalidateAndCancel()
        continuation = nil
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress?(min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // 先清理可能存在的旧文件，再移动（同卷 move 是原子操作）
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: KokoroModelError.downloadFailed(error.localizedDescription))
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: KokoroModelError.downloadFailed(error.localizedDescription))
            continuation = nil
        }
    }
}