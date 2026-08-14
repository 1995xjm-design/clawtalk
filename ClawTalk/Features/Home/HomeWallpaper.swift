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
                palette = AppTokens.wallpaperWarm
            case 2:
                palette = AppTokens.wallpaperDark
            default:
                palette = AppTokens.wallpaperBluePurple
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
            ctx.cgContext.setFillColor(AppTokens.wallpaperGlowWhite.cgColor)
            for i in 0..<3 {
                let cx = size.width * (0.22 + CGFloat(i) * 0.32)
                let cy = size.height * (0.28 + CGFloat(i % 2) * 0.38)
                let r = size.width * 0.38
                ctx.cgContext.fillEllipse(in: CGRect(x: cx - r / 2, y: cy - r / 2, width: r, height: r))
            }
        }
    }

    /// 是否已选择壁纸（区别于「默认纯色」）：自定义照片 或 内置壁纸（任意 id，含 0）。
    /// 默认状态（noWallpaper）= 无壁纸纯色，跟随系统深浅色。
    static func hasSelectedWallpaper(_ settings: AppSettings) -> Bool {
        if settings.homeThemeSource == .customPhoto, settings.customWallpaperPath != nil {
            return true
        }
        if settings.homeThemeSource == .systemWallpaper {
            return true
        }
        return false
    }

    /// S11：全局毛玻璃背景材质——开=ultraThinMaterial 磨砂；关=系统分组背景纯色。
    /// 主页/功能页背景统一走这里，一处跟随 globalGlassEnabled。
    static func glassBackground(enabled: Bool) -> AnyShapeStyle {
        enabled
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(Color(.systemGroupedBackground))
    }

    /// S11：全局毛玻璃卡片材质——开=ultraThinMaterial 磨砂；关=纯色卡片底。
    static func glassCardBackground(enabled: Bool) -> AnyShapeStyle {
        enabled
            ? AnyShapeStyle(.ultraThinMaterial)
            : AnyShapeStyle(Color(.secondarySystemBackground))
    }

    /// 当前主页背景图：自定义照片优先，否则内置壁纸；
    /// 「默认」状态（noWallpaper）返回 nil = 无壁纸纯色；内置壁纸 id 0（蓝紫渐变）正常显示。
    static func currentImage(settings: AppSettings, screenSize: CGSize = UIScreen.main.bounds.size) -> UIImage? {
        if settings.homeThemeSource == .customPhoto,
           let path = settings.customWallpaperPath {
            // 兼容旧版绝对路径；新版本存相对文件名（iOS 更新后沙箱绝对路径会变，绝对路径会让壁纸失效）
            let url: URL
            if path.contains("/") {
                url = URL(fileURLWithPath: path)
            } else if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                url = dir.appendingPathComponent(path)
            } else {
                url = URL(fileURLWithPath: path)
            }
            if let data = try? Data(contentsOf: url),
               let image = UIImage(data: data) {
                return image
            }
        }
        guard settings.homeThemeSource == .systemWallpaper else { return nil }
        return builtinImage(id: settings.homeWallpaperID, size: screenSize)
    }

    /// 保存自定义壁纸到 Documents，返回路径。
    @discardableResult
    static func saveCustomPhoto(_ data: Data) -> String? {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let dir else { return nil }
        // 存相对文件名：iOS 更新/重装后沙箱绝对路径会变，绝对路径会让壁纸失效
        let fileName = "home-wallpaper.jpg"
        let url = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            return fileName
        } catch {
            return nil
        }
    }
}
