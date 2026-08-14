//
//  ClawTalkIOSNativePalette.swift
//
//  ClawTalk「IOS原生」全套页面：全局色值/尺寸按官方文档写死，深浅两套，不随主题变化。
//

import UIKit

/// ClawTalk「IOS原生」页面全局色值/尺寸（按官方文档，写死）
enum ClawIOSNativePalette {
  // MARK: - 深浅两套配色（文档）

  /// 单套配色
  struct ClawNativeColors {
    /// 键盘底盘
    let keyboardBackground: UIColor
    /// 普通键
    let keyNormal: UIColor
    /// 功能/跳转键
    let keyFunction: UIColor
    /// 发送键
    let keySend: UIColor
    /// 按下-普通键
    let keyNormalPressed: UIColor
    /// 按下-功能键
    let keyFunctionPressed: UIColor
    /// 按下-发送键
    let keySendPressed: UIColor
    /// 按键文字
    let keyText: UIColor
    /// 候选栏背景
    let candidateBarBackground: UIColor
  }

  /// 浅色套（文档）
  static let lightColors = ClawNativeColors(
    keyboardBackground: UIColor(hex: 0xD1D1D1),
    keyNormal: UIColor(hex: 0xFFFFFF),
    keyFunction: UIColor(hex: 0xB0B0B0),
    keySend: UIColor(hex: 0x007AFF),
    keyNormalPressed: UIColor(hex: 0x949494),
    keyFunctionPressed: UIColor(hex: 0x767676),
    keySendPressed: UIColor(hex: 0x0058CC),
    keyText: UIColor(hex: 0x000000),
    candidateBarBackground: UIColor(hex: 0xE8E8E8)
  )

  /// 深色套（文档）
  static let darkColors = ClawNativeColors(
    keyboardBackground: UIColor(hex: 0x1C1C1E),
    keyNormal: UIColor(hex: 0x3A3A3C),
    keyFunction: UIColor(hex: 0x48484A),
    keySend: UIColor(hex: 0x007AFF),
    keyNormalPressed: UIColor(hex: 0x636366),
    keyFunctionPressed: UIColor(hex: 0x545456),
    keySendPressed: UIColor(hex: 0x0058CC),
    keyText: UIColor(hex: 0xFFFFFF),
    candidateBarBackground: UIColor(hex: 0x2C2C2E)
  )

  /// 按当前界面样式取色
  static func colors(for style: UIUserInterfaceStyle) -> ClawNativeColors {
    style == .dark ? darkColors : lightColors
  }

  // MARK: - 尺寸常量（文档）

  /// 键盘总宽
  static let keyboardWidth: CGFloat = 375

  /// 按键区高（不含候选栏）
  static let keyAreaHeight: CGFloat = 216

  /// 候选栏高
  static let candidateRowHeight: CGFloat = 44

  /// 按键圆角
  static let keyCornerRadius: CGFloat = 8

  /// 横向间距
  static let gapH: CGFloat = 6

  /// 纵向间距
  static let gapV: CGFloat = 6

  /// 水平内边距
  static let paddingH: CGFloat = 8

  /// 垂直内边距
  static let paddingV: CGFloat = 8

  /// 按键行高
  static let rowHeight: CGFloat = 46

  /// 底部系统栏高（🌐🎤 44×40）
  static let bottomBarHeight: CGFloat = 44

  /// 按键内容内边距（gap 的一半，保证键帽间距 = gap）
  static let keyInset: CGFloat = gapH / 2

  // MARK: - 按键类型（普通 / 功能 / 发送）

  enum ClawKeyType {
    case normal
    case function
    case send
  }

  /// 按动作分类按键：primary=发送（换行/回车=功能灰）；system=功能；其余=普通
  static func keyType(for action: KeyboardAction) -> ClawKeyType {
    if action.isPrimaryAction {
      if case .primary(let type) = action, type.isSystemAction { return .function }
      return .send
    }
    if action.isSystemAction { return .function }
    switch action {
    case .t9SelectPinyin, .t9ConfirmCandidate, .delimiter:
      return .function
    default:
      return .normal
    }
  }

  /// 按键背景色（按类型 + 按下状态 + 深浅套）
  static func backgroundColor(for action: KeyboardAction, isPressed: Bool, style: UIUserInterfaceStyle) -> UIColor {
    let c = colors(for: style)
    switch keyType(for: action) {
    case .send: return isPressed ? c.keySendPressed : c.keySend
    case .function: return isPressed ? c.keyFunctionPressed : c.keyFunction
    case .normal: return isPressed ? c.keyNormalPressed : c.keyNormal
    }
  }

  /// 候选栏背景（按深浅套）
  static func candidateBarBackground(for style: UIUserInterfaceStyle) -> UIColor {
    colors(for: style).candidateBarBackground
  }

  /// 底部系统栏图标色
  static func bottomBarIcon(for style: UIUserInterfaceStyle) -> UIColor {
    colors(for: style).keyFunctionPressed
  }

  /// 候选栏选中高亮（文档：始终 #007AFF）
  static let candidateSelected = UIColor(hex: 0x007AFF)

  /// 收起箭头
  static func collapseArrow(for style: UIUserInterfaceStyle) -> UIColor {
    style == .dark ? UIColor(hex: 0x98989E) : UIColor(hex: 0x86868B)
  }

  // MARK: - 按钮样式

  /// 生成 IOS原生 页面按键样式（色值按文档写死）
  static func buttonStyle(for action: KeyboardAction, keyboardType: KeyboardType, isPressed: Bool, style: UIUserInterfaceStyle) -> KeyboardButtonStyle {
    let colors = colors(for: style)
    let backgroundColor: UIColor
    if action.isShiftAction, keyboardType.isAlphabeticUppercased {
      // 大写态 SHIFT 高亮 = 功能键按下色
      backgroundColor = colors.keyFunctionPressed
    } else {
      backgroundColor = Self.backgroundColor(for: action, isPressed: isPressed, style: style)
    }
    return KeyboardButtonStyle(
      backgroundColor: backgroundColor,
      foregroundColor: colors.keyText,
      swipeForegroundColor: UIColor.secondaryLabel,
      font: UIFont.systemFont(ofSize: action.isSystemAction || action.isPrimaryAction ? 16 : 20, weight: .regular),
      swipeFont: UIFont.systemFont(ofSize: 8),
      cornerRadius: keyCornerRadius,
      border: nil,
      shadow: nil
    )
  }

  /// IOS原生 候选栏样式（色值按文档写死）
  static func candidateBarStyle(for style: UIUserInterfaceStyle) -> CandidateBarStyle {
    let colors = colors(for: style)
    return CandidateBarStyle(
      phoneticTextColor: colors.keyText,
      phoneticTextFont: .systemFont(ofSize: 14),
      preferredCandidateTextColor: candidateSelected,
      preferredCandidateCommentTextColor: candidateSelected,
      preferredCandidateBackgroundColor: UIColor.clear,
      preferredCandidateLabelColor: candidateSelected,
      candidateTextColor: colors.keyText,
      candidateCommentTextColor: colors.keyText,
      candidateLabelColor: colors.keyText,
      candidateLabelFont: .systemFont(ofSize: 12),
      candidateTextFont: .systemFont(ofSize: 18),
      candidateCommentFont: .systemFont(ofSize: 12),
      toolbarButtonFrontColor: colors.keyFunctionPressed,
      toolbarButtonBackgroundColor: UIColor.clear,
      toolbarButtonPressedBackgroundColor: UIColor.secondarySystemFill
    )
  }
}

extension UIColor {
  /// 从 24 位 HEX 色值创建颜色（0xRRGGBB）
  convenience init(hex: UInt32) {
    let red = CGFloat((hex >> 16) & 0xFF) / 255.0
    let green = CGFloat((hex >> 8) & 0xFF) / 255.0
    let blue = CGFloat(hex & 0xFF) / 255.0
    self.init(red: red, green: green, blue: blue, alpha: 1.0)
  }
}

extension KeyboardContext {
  /// 当前键盘候选栏高度：中文九宫格（含 IOS原生）双层 88pt，其余页面单层 44pt
  var clawCandidateBarHeight: CGFloat {
    keyboardType.isChineseNineGrid
      ? ClawIOSNativePalette.candidateRowHeight * 2
      : ClawIOSNativePalette.candidateRowHeight
  }

  /// 是否为 ClawTalk「IOS原生」模式（主页为 IOS原生 九宫格时，英文页也走 QWERTY/原生配色）
  var isClawIOSNativeMode: Bool {
    selectKeyboard.isClawIOSNativeKeyboard
  }

  /// 当前页面是否使用 IOS原生 写死配色（含英文 QWERTY 页）
  var isClawIOSNativeStyled: Bool {
    keyboardType.isClawIOSNativeKeyboard || (isClawIOSNativeMode && keyboardType.isAlphabetic)
  }
}

extension KeyboardType {
  /// 是否为 ClawTalk「IOS原生」系列页面（色值写死的键盘页面）
  var isClawIOSNativeKeyboard: Bool {
    switch self {
    case .chineseNineGrid, .chineseNineGridIOS, .numericNineGrid, .classifySymbolic, .englishT9,
         .numericMoreSymbols, .classifySymbolicMore, .englishNumeric, .englishSymbolsMore:
      return true
    default:
      return false
    }
  }
}
