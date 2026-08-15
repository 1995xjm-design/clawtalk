import Foundation
import Photos

/// 媒体库能力（任务 A3a）：读取相册最近的照片/视频元数据（不含图像数据，避免 token 膨胀）。
/// 权限不足（拒绝/受限）返回明确错误。
/// 注：官方协议（shared/OpenClawKit OpenClawPhotosCommand）仅有 photos.latest（宿主由 PhotosCapability 承担），
/// 无独立 media.* 媒体控制命令；官方"媒体"实现 apps/ios/Sources/Media/PhotoLibraryService.swift 亦为相册读取。
/// 因此本文件维持宿主 media.list 元数据读取（真实 PHPhotoLibrary 数据，无假数据）。
enum MediaCapability {

    struct MediaItem: Encodable {
        let identifier: String
        let mediaType: String // image / video / audio / unknown
        let creationDate: String?
        let width: Int
        let height: Int
        let duration: Double
        let isFavorite: Bool
    }

    enum MediaError: LocalizedError {
        case denied
        case restricted
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied: return "照片权限被拒绝"
            case .restricted: return "照片权限受系统限制"
            case .failed(let message): return message
            }
        }
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 读取最近 count 条媒体（照片+视频），按创建时间倒序；count 钳制在 1...200 防止响应过大。
    static func recent(count: Int = 20) async throws -> [MediaItem] {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized, .limited:
            break
        case .denied:
            throw MediaError.denied
        case .restricted:
            throw MediaError.restricted
        case .notDetermined:
            throw MediaError.failed("照片权限状态未确定，请重试")
        @unknown default:
            throw MediaError.failed("照片权限状态未知")
        }

        let limit = min(max(1, count), 200)
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        let assets = PHAsset.fetchAssets(with: options)

        var items: [MediaItem] = []
        assets.enumerateObjects { asset, _, _ in
            let mediaType: String
            switch asset.mediaType {
            case .image: mediaType = "image"
            case .video: mediaType = "video"
            case .audio: mediaType = "audio"
            default: mediaType = "unknown"
            }
            items.append(MediaItem(
                identifier: asset.localIdentifier,
                mediaType: mediaType,
                creationDate: asset.creationDate.map { formatter.string(from: $0) },
                width: asset.pixelWidth,
                height: asset.pixelHeight,
                duration: asset.duration,
                isFavorite: asset.isFavorite
            ))
        }
        return items
    }
}
