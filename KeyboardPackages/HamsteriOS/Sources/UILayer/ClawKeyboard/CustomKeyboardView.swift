//
//  CustomKeyboardView.swift
//
//  ClawTalk 键盘模拟组件（SwiftUI，运行在 App 页面内部，非系统键盘扩展）
//
//  - 复用入口：ClawKeyboardSimulatorView 通过 @Binding 传入 showTopPanel 与输入文本
//  - 右侧竖排按钮随 showTopPanel 动态切换：
//      收起(showTopPanel=false)：删除 / 换行 / 发送(灰色禁用)
//      展开(showTopPanel=true) ：删除 / 重输 / 换行
//  - 左下角按键固定显示「符号」（替代 #+=）
//  - 字母 / 数字 / 空格 / 中英切换 / 麦克风 / 地球 样式统一，不随面板状态变化
//

import SwiftUI
import UIKit

// MARK: - 模拟键盘配色

private enum SimKeyPalette {
  static func adaptive(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark ? dark : light
    })
  }

  /// 键盘面板底色（浅 #D1D4D9 / 深 #1B1B1F）
  static let background = adaptive(
    light: UIColor(red: 209 / 255, green: 212 / 255, blue: 217 / 255, alpha: 1),
    dark: UIColor(red: 27 / 255, green: 27 / 255, blue: 31 / 255, alpha: 1)
  )

  /// 字母键 / 空格键（白 / 深黑）
  static let letterKey = adaptive(
    light: UIColor.white,
    dark: UIColor(red: 19 / 255, green: 21 / 255, blue: 28 / 255, alpha: 1)
  )

  /// 功能键（删除 / 换行 / 重输 / 符号 / 中英切换，灰底）
  static let functionKey = adaptive(
    light: UIColor(red: 228 / 255, green: 230 / 255, blue: 234 / 255, alpha: 1),
    dark: UIColor(red: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
  )

  /// 发送键：蓝色（可用）/ 灰色（禁用）
  static let sendBlue = Color(red: 48 / 255, green: 120 / 255, blue: 246 / 255)
  static let sendDisabled = adaptive(
    light: UIColor(red: 200 / 255, green: 203 / 255, blue: 208 / 255, alpha: 1),
    dark: UIColor(red: 60 / 255, green: 60 / 255, blue: 64 / 255, alpha: 1)
  )

  /// 按键文字色
  static let keyLabel = adaptive(
    light: UIColor(red: 17 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1),
    dark: UIColor.white
  )

  /// 禁用态文字色
  static let disabledLabel = adaptive(
    light: UIColor(red: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1),
    dark: UIColor(red: 142 / 255, green: 142 / 255, blue: 147 / 255, alpha: 1)
  )
}

// MARK: - 按键样式

private enum SimKeyStyle {
  case letter
  case function
  case space
  case send
}

// MARK: - 按键按压反馈

private struct SimKeyButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.65 : 1)
      .scaleEffect(configuration.isPressed ? 0.96 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

// MARK: - 模拟键盘按键

private struct SimKeyButton: View {
  let label: String
  let width: CGFloat?
  let height: CGFloat
  let style: SimKeyStyle
  let isEnabled: Bool
  let action: () -> Void

  init(
    _ label: String,
    width: CGFloat? = nil,
    height: CGFloat = 44,
    style: SimKeyStyle = .letter,
    isEnabled: Bool = true,
    action: @escaping () -> Void
  ) {
    self.label = label
    self.width = width
    self.height = height
    self.style = style
    self.isEnabled = isEnabled
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(font)
        .foregroundColor(foregroundColor)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width, height: height)
        .background(backgroundColor)
        .cornerRadius(7)
    }
    .buttonStyle(SimKeyButtonStyle())
    .disabled(!isEnabled)
  }

  private var font: Font {
    switch style {
    case .send:
      return .system(size: 16, weight: .semibold)
    case .function:
      return .system(size: 15)
    default:
      return .system(size: 20)
    }
  }

  private var foregroundColor: Color {
    if !isEnabled {
      return SimKeyPalette.disabledLabel
    }
    switch style {
    case .send:
      return .white
    default:
      return SimKeyPalette.keyLabel
    }
  }

  private var backgroundColor: Color {
    switch style {
    case .send:
      return isEnabled ? SimKeyPalette.sendBlue : SimKeyPalette.sendDisabled
    case .function:
      return SimKeyPalette.functionKey
    default:
      return SimKeyPalette.letterKey
    }
  }
}

// MARK: - 模拟键盘组件（可复用）

struct CustomKeyboardView: View {
  // MARK: 注入状态
  @Binding var showTopPanel: Bool
  @Binding var text: String

  // MARK: 内部状态
  @State private var isChinese = true
  @State private var isShifted = false
  @State private var showingSymbols = false

  // MARK: 布局常量
  private let spacing: CGFloat = 6
  private let keyHeight: CGFloat = 44
  private let rightColumnWidth: CGFloat = 68

  var body: some View {
    VStack(spacing: spacing) {
      HStack(spacing: spacing) {
        // 主键盘区（字母 / 符号 切换）
        VStack(spacing: spacing) {
          if showingSymbols {
            symbolPad
          } else {
            letterPad
          }
          bottomRow
        }

        // 右侧竖排按钮（随 showTopPanel 动态切换）
        rightColumn
      }

      // 底部图标条：地球 / 麦克风
      iconStrip
    }
    .padding(.horizontal, spacing)
    .padding(.vertical, spacing)
    .background(SimKeyPalette.background)
  }

  // MARK: 字母区（三行 QWERTY）
  private var letterPad: some View {
    VStack(spacing: spacing) {
      letterRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])
      letterRow(["a", "s", "d", "f", "g", "h", "j", "k", "l"])
      shiftRow
    }
  }

  private func letterRow(_ letters: [String]) -> some View {
    HStack(spacing: spacing) {
      ForEach(letters, id: \.self) { letter in
        SimKeyButton(displayLetter(letter)) {
          text.append(displayLetter(letter))
        }
      }
    }
  }

  private var shiftRow: some View {
    HStack(spacing: spacing) {
      SimKeyButton("⇧", width: 56, style: .function) {
        isShifted.toggle()
      }
      ForEach(["z", "x", "c", "v", "b", "n", "m"], id: \.self) { letter in
        SimKeyButton(displayLetter(letter)) {
          text.append(displayLetter(letter))
        }
      }
      SimKeyButton("⌫", width: 56, style: .function) {
        if !text.isEmpty { text.removeLast() }
      }
    }
  }

  // MARK: 符号区（数字 / 常用符号）
  private var symbolPad: some View {
    VStack(spacing: spacing) {
      symbolRow(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
      symbolRow(["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""])
      HStack(spacing: spacing) {
        ForEach([".", ",", "?", "!", "'"], id: \.self) { symbol in
          SimKeyButton(symbol) {
            text.append(symbol)
          }
        }
        SimKeyButton("⌫", width: 56, style: .function) {
          if !text.isEmpty { text.removeLast() }
        }
      }
    }
  }

  private func symbolRow(_ symbols: [String]) -> some View {
    HStack(spacing: spacing) {
      ForEach(symbols, id: \.self) { symbol in
        SimKeyButton(symbol) {
          text.append(symbol)
        }
      }
    }
  }

  // MARK: 底部功能行（左下角固定「符号」）
  private var bottomRow: some View {
    HStack(spacing: spacing) {
      SimKeyButton(showingSymbols ? "ABC" : "符号", width: 64, style: .function) {
        showingSymbols.toggle()
      }
      SimKeyButton(isChinese ? "空格" : "space", style: .space) {
        text.append(" ")
      }
      SimKeyButton(isChinese ? "中" : "EN", width: 56, style: .function) {
        isChinese.toggle()
        isShifted = false
      }
    }
  }

  // MARK: 右侧竖排按钮（核心动态切换逻辑）
  private var rightColumn: some View {
    VStack(spacing: spacing) {
      if showTopPanel {
        // 状态B（面板展开）：删除 / 重输 / 换行，无发送按钮
        SimKeyButton("删除", width: rightColumnWidth, height: 60, style: .function) {
          if !text.isEmpty { text.removeLast() }
        }
        SimKeyButton("重输", width: rightColumnWidth, height: 60, style: .function) {
          text = ""
        }
        SimKeyButton("换行", width: rightColumnWidth, height: 60, style: .function) {
          text.append("\n")
        }
      } else {
        // 状态A（面板收起）：删除 / 换行 / 发送(灰色禁用)
        SimKeyButton("删除", width: rightColumnWidth, height: 60, style: .function) {
          if !text.isEmpty { text.removeLast() }
        }
        SimKeyButton("换行", width: rightColumnWidth, height: 60, style: .function) {
          text.append("\n")
        }
        SimKeyButton("发送", width: rightColumnWidth, height: 60, style: .send, isEnabled: false) {}
      }
    }
    .frame(width: rightColumnWidth)
  }

  // MARK: 底部图标条（地球 / 麦克风，样式保持原样）
  private var iconStrip: some View {
    HStack {
      Button(action: {}) {
        Image(systemName: "globe")
      }
      Spacer()
      Button(action: {}) {
        Image(systemName: "mic.fill")
      }
    }
    .font(.system(size: 17))
    .foregroundColor(SimKeyPalette.keyLabel)
    .buttonStyle(.plain)
    .frame(height: 24)
    .padding(.horizontal, 6)
  }

  // MARK: 字母显示（中/英、大写/小写）
  private func displayLetter(_ letter: String) -> String {
    (isShifted || !isChinese) ? letter.uppercased() : letter
  }
}
