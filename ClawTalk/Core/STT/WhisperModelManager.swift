import Foundation
import WhisperKit

enum WhisperModelError: Error {
    case downloadFailed
}

@Observable
@MainActor
final class WhisperModelManager {
    static let shared = WhisperModelManager()

    var isDownloading = false
    var downloadProgress: Double = 0
    var isModelReady = false
    var errorMessage: String?

    private let defaults = UserDefaults.standard
    private let downloadedKey = "whisper_model_downloaded"

    var hasDownloadedModel: Bool {
        defaults.bool(forKey: downloadedKey)
    }

    func checkModelAvailable(for size: WhisperModelSize) -> Bool {
        let modelName = size.rawValue
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelDir = documentsURL.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-\(modelName)")
        return FileManager.default.fileExists(atPath: modelDir.path)
    }

    func downloadModel(size: WhisperModelSize) async {
        isDownloading = true
        downloadProgress = 0
        errorMessage = nil

        do {
            // 国内优先：先试 hf-mirror.com（国内镜像），失败再回退官方 huggingface.co。
            // WhisperKit.download 支持 endpoint 参数（仓库 argmaxinc/whisperkit-coreml）。
            let mirrors = ["https://hf-mirror.com", "https://huggingface.co"]
            var modelURL: URL?
            var lastError: Error?
            for mirror in mirrors {
                do {
                    modelURL = try await WhisperKit.download(
                        variant: size.rawValue,
                        from: "argmaxinc/whisperkit-coreml",
                        endpoint: mirror,
                        progressCallback: { [weak self] progress in
                            Task { @MainActor in
                                self?.downloadProgress = progress.fractionCompleted
                            }
                        }
                    )
                    break
                } catch {
                    lastError = error
                    print("[whisper] \(mirror) 下载失败: \(error.localizedDescription)")
                }
            }
            guard let modelURL else {
                throw lastError ?? WhisperModelError.downloadFailed
            }

            // Initialize with local model (no re-download)
            let config = WhisperKitConfig(
                modelFolder: modelURL.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            )
            _ = try await WhisperKit(config)

            isModelReady = true
            isDownloading = false
            downloadProgress = 1.0
            defaults.set(true, forKey: downloadedKey)
        } catch {
            isDownloading = false
            errorMessage = "模型下载失败：\(error.localizedDescription)"
        }
    }
}
