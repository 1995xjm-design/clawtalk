//
//  ClawTalkTheme.swift
//  ClawTalk 键盘 7 套主题预设
//
//  默认（系统）= 苹果原生配色：浅色白底浅灰键 / 深色黑底深灰键，跟随系统，无品牌强调。
//  7 套主题：红 / 白 / 黑 / 黑金 / 海盐蓝 / 森林绿 / 樱花粉。
//  每套定义：键帽底 / 键帽字 / 键盘底色 / 强调色 / 选中高亮（含浅、深两套变体）。
//

import Foundation
import UIKit

// MARK: - 颜色转换辅助

/// 将 "#RRGGBB" 转为 RIME 配色字符串 "0xBBGGRR"（24 位 BGR 顺序）
public func rimeBGRString(_ rgbHex: String) -> String {
  var hex = rgbHex
  if hex.hasPrefix("#") { hex.removeFirst() }
  guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return "0x000000" }
  let r = (value >> 16) & 0xFF
  let g = (value >> 8) & 0xFF
  let b = value & 0xFF
  return String(format: "0x%02X%02X%02X", b, g, r)
}

/// 将 "#RRGGBB" 转为 UIColor
public func uiColorFromHex(_ rgbHex: String) -> UIColor {
  var hex = rgbHex
  if hex.hasPrefix("#") { hex.removeFirst() }
  guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return .clear }
  return UIColor(
    red: CGFloat((value >> 16) & 0xFF) / 255,
    green: CGFloat((value >> 8) & 0xFF) / 255,
    blue: CGFloat(value & 0xFF) / 255,
    alpha: 1
  )
}

// MARK: - 主题枚举

/// ClawTalk 键盘主题（7 套，索引 0 为系统默认/苹果原生）
public enum ClawTalkTheme: String, CaseIterable, Codable {
  case red = "clawtalk_red"
  case white = "clawtalk_white"
  case black = "clawtalk_black"
  case blackGold = "clawtalk_black_gold"
  case seaSaltBlue = "clawtalk_sea_blue"
  case forestGreen = "clawtalk_forest"
  case cherryBlossom = "clawtalk_sakura"

  /// 设置页展示名称
  public var displayName: String {
    switch self {
    case .red: return "红"
    case .white: return "白"
    case .black: return "黑"
    case .blackGold: return "黑金"
    case .seaSaltBlue: return "海盐蓝"
    case .forestGreen: return "森林绿"
    case .cherryBlossom: return "樱花粉"
    }
  }

  /// 设置页副标题
  public var displaySubtitle: String {
    switch self {
    case .red: return "ClawTalk 品牌红"
    case .white: return "简约纯净白"
    case .black: return "深邃酷黑"
    case .blackGold: return "黑金质感"
    case .seaSaltBlue: return "清爽海盐蓝"
    case .forestGreen: return "自然森林绿"
    case .cherryBlossom: return "温柔樱花粉"
    }
  }
}

// MARK: - 主题 RGB 定义

/// 主题单套变体的原始 RGB 色值（十六进制字符串）
public struct ClawTalkThemeRGB {
  public let keyboardBackground: String // 键盘底色
  public let keycapBase: String // 键帽底
  public let keycapPressed: String // 键帽按下底
  public let keycapText: String // 键帽字
  public let accent: String // 强调色
  public let accentForeground: String // 强调色上的前景文字

  public init(
    keyboardBackground: String,
    keycapBase: String,
    keycapPressed: String,
    keycapText: String,
    accent: String,
    accentForeground: String
  ) {
    self.keyboardBackground = keyboardBackground
    self.keycapBase = keycapBase
    self.keycapPressed = keycapPressed
    self.keycapText = keycapText
    self.accent = accent
    self.accentForeground = accentForeground
  }
}

// MARK: - 主题预设

/// 主题预设：浅/深两套 KeyboardColorSchema + 面板取色用 RGB
public struct ClawTalkThemePreset {
  public let theme: ClawTalkTheme
  public let displayName: String
  public let lightRGB: ClawTalkThemeRGB
  public let darkRGB: ClawTalkThemeRGB
  public let lightSchema: KeyboardColorSchema
  public let darkSchema: KeyboardColorSchema

  public var lightSchemaName: String { lightSchema.schemaName ?? "" }
  public var darkSchemaName: String { darkSchema.schemaName ?? "" }
}

/// 面板跟随主题的取色结构
public struct ClawPanelThemeColors {
  public let keycapBase: UIColor
  public let keycapPressed: UIColor
  public let keycapText: UIColor
  public let keyboardBackground: UIColor
  public let accent: UIColor
  public let accentForeground: UIColor
  public let selectedHighlight: UIColor
}

// MARK: - 预设表

public enum ClawTalkThemePresets {
  /// 7 套主题全部预设（顺序 = 设置页选项顺序 1...7）
  public static let all: [ClawTalkThemePreset] = ClawTalkTheme.allCases.map { preset(for: $0) }

  /// 按主题取预设
  public static func preset(for theme: ClawTalkTheme) -> ClawTalkThemePreset {
    switch theme {
    case .red:
      return makePreset(
        theme: theme,
        light: ClawTalkThemeRGB(
          keyboardBackground: "#F6F7F9", keycapBase: "#FFFFFF", keycapPressed: "#F0E6E6",
          keycapText: "#1C1C1E", accent: "#B73833", accentForeground: "#FFFFFF"
        ),
        dark: ClawTalkThemeRGB(
          keyboardBackground: "#13151C", keycapBase: "#23262F", keycapPressed: "#333844",
          keycapText: "#F2F2F7", accent: "#C63E38", accentForeground: "#FFFFFF"
        )
      )
    case .white:
      return makePreset(
        theme: theme,
        light: ClawTalkThemeRGB(
          keyboardBackground: "#F2F2F7", keycapBase: "#FFFFFF", keycapPressed: "#E5E5EA",
          keycapText: "#1C1C1E", accent: "#6E6E73", accentForeground: "#FFFFFF"
        ),
        dark: ClawTalkThemeRGB(
          keyboardBackground: "#1C1C1E", keycapBase: "#2C2C2E", keycapPressed: "#3A3A3C",
          keycapText: "#FFFFFF", accent: "#98989D", accentForeground: "#1C1C1E"
        )
      )
    case .black:
      return makePreset(
        theme: theme,
        light: ClawTalkThemeRGB(
          keyboardBackground: "#1C1C1E", keycapBase: "#2C2C2E", keycapPressed: "#3A3A3C",
          keycapText: "#FFFFFF", accent: "#8E8E93", accentForeground: "#FFFFFF"
        ),
        dark: ClawTalkThemeRGB(
          keyboardBackground: "#000000", keycapBase: "#1C1C1E", keycapPressed: "#2C2C2E",
          keycapText: "#FFFFFF", accent: "#98989D", accentForeground: "#000000"
        )
      )
    case .blackGold:
      return makePreset(
        theme: theme,
        light: ClawTalkThemeRGB(
          keyboardBackground: "#141210", keycapBase: "#1F1D1A", keycapPressed: "#2E2B26",
          keycapText: "#F5F1E8", accent: "#D4AF37", accentForeground: "#141210"
        ),
        dark: ClawTalkThemeRGB(
          keyboardBackground: "#000000", keycapBase: "#1A1815", keycapPressed: "#292621",
          keycapText: "#F5F1E8", accent: "#E5C158", accentForeground: "#141210"
        )
      )
    case .seaSaltBlue:
      return makePreset(
        theme: theme,
        light: ClawTalkThemeRGB(
          keyboardBackground: "#EAF2FA", keycapBase: "#FFFFFF", keycapPressed: "#DCE9F5",
          keycapText: "#1C2733", accent: "#3B7DD8", accentForeground: "#FFFFFF"
        ),
        dark: ClawTalkThemeRGB(
          keyboardBackground: "#0E1B2A", keycapBase: "#1B2C42", keycapPressed: "#26405E",
          keycapText: "#E8F0F8", accent: "#5E9CEA", accentForeground: "#0E1B2A"
        )
      )
    case .forestGreen:
      return makePreset(
        theme: theme,
        light: ClawTalkThemeRGB(
          keyboardBackground: "#EEF4EE", keycapBase: "#FFFFFF", keycapPressed: "#DFEBE1",
          keycapText: "#1B2A20", accent: "#2E7D4F", accentForeground: "#FFFFFF"
        ),
        dark: ClawTalkThemeRGB(
          keyboardBackground: "#0F1D15", keycapBase: "#1B2E22", keycapPressed: "#26402F",
          keycapText: "#E4EFE7", accent: "#4CAF78", accentForeground: "#0F1D15"
        )
      )
    case .cherryBlossom:
      return makePreset(
        theme: theme,
        light: ClawTalkThemeRGB(
          keyboardBackground: "#FDF1F4", keycapBase: "#FFFFFF", keycapPressed: "#F7E0E7",
          keycapText: "#4A2A33", accent: "#E86A92", accentForeground: "#FFFFFF"
        ),
        dark: ClawTalkThemeRGB(
          keyboardBackground: "#2A151C", keycapBase: "#3A1E28", keycapPressed: "#4C2836",
          keycapText: "#F6E3E9", accent: "#F58BB0", accentForeground: "#2A151C"
        )
      )
    }
  }

  /// 按 schema 名（浅/深任一）找主题
  public static func theme(forSchemaName name: String?) -> ClawTalkTheme? {
    guard let name else { return nil }
    return all.first { $0.lightSchemaName == name || $0.darkSchemaName == name }?.theme
  }

  /// 按 schema 名取内置预设 schema（键盘扩展兜底用）
  public static func schema(named name: String?) -> KeyboardColorSchema? {
    guard let name else { return nil }
    return all.flatMap { [$0.lightSchema, $0.darkSchema] }.first { $0.schemaName == name }
  }

  private static func makePreset(theme: ClawTalkTheme, light: ClawTalkThemeRGB, dark: ClawTalkThemeRGB) -> ClawTalkThemePreset {
    ClawTalkThemePreset(
      theme: theme,
      displayName: theme.displayName,
      lightRGB: light,
      darkRGB: dark,
      lightSchema: makeSchema(schemaName: "\(theme.rawValue)", name: "\(theme.displayName)（浅色）", rgb: light),
      darkSchema: makeSchema(schemaName: "\(theme.rawValue)_dark", name: "\(theme.displayName)（深色）", rgb: dark)
    )
  }

  /// 由 RGB 定义构建 RIME KeyboardColorSchema
  private static func makeSchema(schemaName: String, name: String, rgb: ClawTalkThemeRGB) -> KeyboardColorSchema {
    let keyText = rimeBGRString(rgb.keycapText)
    let accent = rimeBGRString(rgb.accent)
    let accentFront = rimeBGRString(rgb.accentForeground)
    return KeyboardColorSchema(
      schemaName: schemaName,
      name: name,
      author: "ClawTalk",
      backColor: rimeBGRString(rgb.keyboardBackground),
      buttonBackColor: rimeBGRString(rgb.keycapBase),
      buttonPressedBackColor: rimeBGRString(rgb.keycapPressed),
      buttonFrontColor: keyText,
      buttonPressedFrontColor: keyText,
      buttonSwipeFrontColor: keyText,
      cornerRadius: 5,
      borderColor: "0x00000000",
      textColor: keyText,
      hilitedTextColor: keyText,
      hilitedBackColor: rimeBGRString(rgb.keycapBase),
      hilitedCandidateTextColor: accentFront,
      hilitedCandidateBackColor: accent,
      hilitedCommentTextColor: accentFront,
      hilitedCandidateLabelColor: accentFront,
      candidateTextColor: keyText,
      commentTextColor: keyText,
      labelColor: keyText
    )
  }
}

// MARK: - 面板取色

public extension ClawTalkThemePreset {
  /// 面板跟随主题取色（含浅/深变体）
  func panelColors(userInterfaceStyle: UIUserInterfaceStyle) -> ClawPanelThemeColors {
    let rgb = userInterfaceStyle == .dark ? darkRGB : lightRGB
    return ClawPanelThemeColors(
      keycapBase: uiColorFromHex(rgb.keycapBase),
      keycapPressed: uiColorFromHex(rgb.keycapPressed),
      keycapText: uiColorFromHex(rgb.keycapText),
      keyboardBackground: uiColorFromHex(rgb.keyboardBackground),
      accent: uiColorFromHex(rgb.accent),
      accentForeground: uiColorFromHex(rgb.accentForeground),
      selectedHighlight: uiColorFromHex(rgb.accent)
    )
  }
}

public extension ClawPanelThemeColors {
  /// 系统默认（苹果原生）面板取色
  static func system(userInterfaceStyle: UIUserInterfaceStyle) -> ClawPanelThemeColors {
    if userInterfaceStyle == .dark {
      return ClawPanelThemeColors(
        keycapBase: uiColorFromHex("#636366"),
        keycapPressed: uiColorFromHex("#48484A"),
        keycapText: UIColor.white,
        keyboardBackground: uiColorFromHex("#17181A"),
        accent: uiColorFromHex("#0A84FF"),
        accentForeground: UIColor.white,
        selectedHighlight: uiColorFromHex("#0A84FF")
      )
    }
    return ClawPanelThemeColors(
      keycapBase: UIColor.white,
      keycapPressed: uiColorFromHex("#E5E5EA"),
      keycapText: uiColorFromHex("#111111"),
      keyboardBackground: uiColorFromHex("#D1D4D9"),
      accent: uiColorFromHex("#007AFF"),
      accentForeground: UIColor.white,
      selectedHighlight: uiColorFromHex("#007AFF")
    )
  }
}
