import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#endif

// 只在非键盘扩展中导入SwiftUI
#if canImport(SwiftUI) && !KEYBOARD_EXTENSION
import SwiftUI
#endif

// MARK: - App常量
struct AppConstants {
    // App Groups ID
    static let appGroupId = "group.com.openclaw.clawtalk"

    // Bundle IDs
    static let mainAppBundleId = "com.openclaw.clawtalk"
    static let keyboardExtensionBundleId = "com.openclaw.clawtalk.keyboard"
}

// MARK: - 键盘布局常量
struct KeyboardLayout {
    static let keyHeight: CGFloat = 42
    static let keySpacing: CGFloat = 6
    static let rowSpacing: CGFloat = 10
    static let sideMargin: CGFloat = 3
    static let toolbarHeight: CGFloat = 44
    static let candidateBarHeight: CGFloat = 40
    static let panelMaxHeight: CGFloat = 300

    // 26键布局
    static let qwertyRows: [[String]] = [
        ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"],
        ["A", "S", "D", "F", "G", "H", "J", "K", "L"],
        ["Z", "X", "C", "V", "B", "N", "M"]
    ]

    // 九宫格布局
    static let t9Keys: [(String, String)] = [
        ("1", ""),
        ("2", "ABC"),
        ("3", "DEF"),
        ("4", "GHI"),
        ("5", "JKL"),
        ("6", "MNO"),
        ("7", "PQRS"),
        ("8", "TUV"),
        ("9", "WXYZ"),
        ("", ""),
        ("0", " "),
        ("", "")
    ]

    // 常用符号
    static let commonSymbols: [String] = [
        "，", "。", "？", "！", "、", "：", "；",
        "（", "）", "【", "】", "《", "》", "…", "～", "·"
    ]

    // 英文符号
    static let englishSymbols: [String] = [
        ",", ".", "?", "!", "'", "\"", ":", ";",
        "(", ")", "[", "]", "{", "}", "-", "_", "/"
    ]

    // Emoji表情
    static let commonEmojis: [String] = [
        "😀", "😂", "🥰", "😍", "😘", "😊", "🤗", "😎",
        "😭", "😢", "😤", "😡", "🥺", "😳", "🤔", "😴",
        "❤️", "💕", "💗", "💖", "✨", "🎉", "👍", "👏",
        "🙏", "💪", "🤝", "👋", "✌️", "🤞", "🫶", "💯"
    ]
}

// MARK: - SwiftUI颜色常量 (仅主App使用)
#if canImport(SwiftUI) && !KEYBOARD_EXTENSION
struct AppColors {
    static let primaryPink = Color(hex: "FF6B95")
    static let secondaryBlue = Color(hex: "5E75FA")
    static let textPrimary = Color(hex: "333333")
    static let textSecondary = Color(hex: "666666")
    static let textHint = Color(hex: "999999")
    static let backgroundGray = Color(hex: "F5F5F5")
    static let white = Color.white
    static let keyBackground = Color.white
    static let keyShadow = Color.black.opacity(0.1)

    // 渐变背景
    static let panelGradient = LinearGradient(
        colors: [Color(hex: "FFF5F7"), Color(hex: "F5F0FF")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - SwiftUI Color扩展
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
#endif

// MARK: - UIKit UIColor扩展
#if canImport(UIKit)
extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }

    static let primaryPink = UIColor(hex: "FF6B95")
    static let secondaryBlue = UIColor(hex: "5E75FA")
    static let textPrimary = UIColor(hex: "333333")
    static let textSecondary = UIColor(hex: "666666")
    static let textHint = UIColor(hex: "999999")
}
#endif
