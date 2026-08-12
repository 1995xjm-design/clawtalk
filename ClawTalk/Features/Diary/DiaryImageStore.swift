import Foundation
import UIKit

/// 日记配图本地存储（F3）：Documents/DiaryImages/ 下按条目 id 存 JPEG。
/// 图片落盘为文件而不是存相册引用，避免后续浏览需要反复申请相册权限。
enum DiaryImageStore {
    private static var directoryURL: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("DiaryImages", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// 保存图片数据，返回文件名（失败返回 nil）。
    @discardableResult
    static func save(_ data: Data, for entryID: UUID) -> String? {
        let filename = entryID.uuidString + ".jpg"
        let url = directoryURL.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            LogCollector.record(module: "日记配图", "保存图片失败：\(error.localizedDescription)")
            return nil
        }
    }

    static func imageURL(filename: String) -> URL {
        directoryURL.appendingPathComponent(filename)
    }

    static func delete(filename: String) {
        let url = directoryURL.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
