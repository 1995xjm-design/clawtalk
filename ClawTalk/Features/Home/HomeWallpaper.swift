import UIKit
import SwiftUI

/// 主页主题壁纸：内置 iOS 风格渐变壁纸（代码生成，无需打包图片资源）+ 自定义照片。
enum HomeWallpaper {
    /// 内置壁纸数量
    static let builtinCount = 3

    /// 渲染内置壁纸：蓝紫（0）/ 暖橙（1）/ 深色（2），渐变 + 柔光斑。
    static func builtinImage(id: Int, size: CGSize) -> UIImage? {
        let normalized = max(0, min(id, builtinCount - 1))
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let palette: [(CGFloat, CGFloat, CGFloat)]
            switch normalized {
            case 1:
                palette = [(0.95, 0.45, 0.25), (0.85, 0.22, 0.45), (0.55, 0.15, 0.55)]
            case 2:
                palette = [(0.10, 0.12, 0.20), (0.16, 0.18, 0.30), (0.08, 0.10, 0.18)]
            default:
                palette = [(0.30, 0.45, 0.90), (0.55, 0.35, 0.85), (0.75, 0.30, 0.70)]
            }
            let cgColors = palette.map {
                UIColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1).cgColor
            } as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: cgColors,
                locations: [0, 0.55, 1]
            )
            if let gradient {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size.width, y: size.height),
                    options: []
                )
            }
            // 柔光斑（iOS 壁纸的云光感）
            ctx.cgContext.setBlendMode(.screen)
            ctx.cgContext.setFillColor(UIColor(red: 1, green: 1, blue: 1, alpha: 0.16).cgColor)
            for i in 0..<3 {
                let cx = size.width * (0.22 + CGFloat(i) * 0.32)
                let cy = size.height * (0.28 + CGFloat(i % 2) * 0.38)
                let r = size.width * 0.38
                ctx.cgContext.fillEllipse(in: CGRect(x: cx - r / 2, y: cy - r / 2, width: r, height: r))
            }
        }
    }

    /// 是否已选择壁纸（区别于「默认纯色」）：自定义照片 或 内置壁纸（id > 0）。
    /// 默认状态（systemWallpaper + id 0）= 无壁纸纯色，跟随系统深浅色。
    static func hasSelectedWallpaper(_ settings: AppSettings) -> Bool {
        if settings.homeThemeSource == .customPhoto, settings.customWallpaperPath != nil {
            return true
        }
        if settings.homeThemeSource == .systemWallpaper, settings.homeWallpaperID > 0 {
            return true
        }
        return false
    }

    /// 当前主页背景图：自定义照片优先，否则内置壁纸；
    /// 「默认」状态（systemWallpaper + id 0）返回 nil = 无壁纸纯色。
    static func currentImage(settings: AppSettings, screenSize: CGSize = UIScreen.main.bounds.size) -> UIImage? {
        if settings.homeThemeSource == .customPhoto,
           let path = settings.customWallpaperPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let image = UIImage(data: data) {
            return image
        }
        guard settings.homeWallpaperID > 0 else { return nil }
        return builtinImage(id: settings.homeWallpaperID, size: screenSize)
    }

    /// 保存自定义壁纸到 Documents，返回路径。
    @discardableResult
    static func saveCustomPhoto(_ data: Data) -> String? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir else { return nil }
        let url = dir.appendingPathComponent("home-wallpaper.jpg")
        do {
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}
