//
//  ClawTalkIOSNativePalette.swift
//
//  ClawTalk「IOS原生」九宫格全套页面：全局色值/圆角写死，不随主题变化。
//

import UIKit

/// ClawTalk「IOS原生」九宫格全套页面全局色值/尺寸（写死）
enum ClawIOSNativePalette {
  // MARK: - 色值（全局统一）

  /// 键盘底板
  static let keyboardBackground = UIColor(hex: 0xD2D2D7)

  /// 按键常态
  static let keyNormal = UIColor(hex: 0xFFFFFF)

  /// 按键按下
  static let keyPressed = UIColor(hex: 0xD1D1D6)

  /// 按键文字
  static let keyText = UIColor(hex: 0x1C1C1E)

  /// 候选栏背景
  static let candidateBarBackground = UIColor(hex: 0xF1F1F3)

  /// 候选文字
  static let candidateText = UIColor(hex: 0x111111)

  /// 选中候选
  static let candidateSelected = UIColor(hex: 0x007AFF)

  /// 收起箭头
  static let collapseArrow = UIColor(hex: 0x86868B)

  /// 底部栏图标
  static let bottomBarIcon = UIColor(hex: 0x636366)

  // MARK: - 尺寸（全局统一）

  /// 按键圆角
  static let keyCornerRadius: CGFloat = 8

  /// 候选栏行高
  static let candidateRowHeight: CGFloat = 44

  /// 底部系统栏高
  static let bottomBarHeight: CGFloat = 50

  // MARK: - 按钮样式

  /// 生成 IOS原生 页面按键样式（色值写死）
  static func buttonStyle(for action: KeyboardAction, isPressed: Bool) -> KeyboardButtonStyle {
    KeyboardButtonStyle(
      backgroundColor: isPressed ? keyPressed : keyNormal,
      foregroundColor: keyText,
      swipeForegroundColor: UIColor.secondaryLabel,
      font: UIFont.systemFont(ofSize: action.isSystemAction || action.isPrimaryAction ? 16 : 20, weight: .regular),
      swipeFont: UIFont.systemFont(ofSize: 8),
      cornerRadius: keyCornerRadius,
      border: nil,
      shadow: nil
    )
  }

  /// IOS原生 候选栏样式（色值写死）
  static var candidateBarStyle: CandidateBarStyle {
    CandidateBarStyle(
      phoneticTextColor: candidateText,
      phoneticTextFont: .systemFont(ofSize: 14),
      preferredCandidateTextColor: candidateSelected,
      preferredCandidateCommentTextColor: candidateSelected,
      preferredCandidateBackgroundColor: UIColor.clear,
      preferredCandidateLabelColor: candidateSelected,
      candidateTextColor: candidateText,
      candidateCommentTextColor: candidateText,
      candidateLabelColor: candidateText,
      candidateLabelFont: .systemFont(ofSize: 12),
      candidateTextFont: .systemFont(ofSize: 18),
      candidateCommentFont: .systemFont(ofSize: 12),
      toolbarButtonFrontColor: bottomBarIcon,
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
}

extension KeyboardType {
  /// 是否为 ClawTalk「IOS原生」九宫格系列页面（色值写死的 4 个键盘页面）
  var isClawIOSNativeKeyboard: Bool {
    switch self {
    case .chineseNineGrid, .chineseNineGridIOS, .numericNineGrid, .classifySymbolic, .englishT9:
      return true
    default:
      return false
    }
  }
}
