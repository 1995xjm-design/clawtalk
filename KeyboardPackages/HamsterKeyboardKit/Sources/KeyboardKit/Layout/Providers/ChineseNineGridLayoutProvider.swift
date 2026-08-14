//
//  File.swift
//
//
//  Created by morse on 2023/9/8.
//

import UIKit

/// 中文九宫格布局（ClawTalk IOS原生）
/// 行1：123 | ,。？！ | ABC | DEF | 删除
/// 行2：#@¥ | GHI | JKL | MNO | 分隔
/// 行3：ABC | PQRS | TUV | WXYZ | 确认(纵向通高)
/// 行4：😀表情 | 选拼音 | 选定 | 确认(纵向通高)
public class ChineseNineGridLayoutProvider: KeyboardLayoutProvider {
  static let actionRows: KeyboardActionRows = [
    [.keyboardType(.numericNineGrid), .chineseNineGrid(Symbol(char: ",。？！")), .keyboardType(.englishT9), .chineseNineGrid(Symbol(char: "DEF")), .backspace],
    [.keyboardType(.classifySymbolic), .chineseNineGrid(Symbol(char: "GHI")), .chineseNineGrid(Symbol(char: "JKL")), .chineseNineGrid(Symbol(char: "MNO")), .delimiter],
    [.keyboardType(.englishT9), .chineseNineGrid(Symbol(char: "PQRS")), .chineseNineGrid(Symbol(char: "TUV")), .chineseNineGrid(Symbol(char: "WXYZ")), .primary(.custom(title: "确认"))],
    [.keyboardType(.emojis), .t9SelectPinyin, .t9ConfirmCandidate],
  ]

  static let insets = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)

  public var insets: UIEdgeInsets {
    Self.insets
  }

  public func keyboardLayout(for context: KeyboardContext) -> KeyboardLayout {
    let actions = actions(context: context)
    let items = self.items(for: actions, context: context)
    return KeyboardLayout(itemRows: items)
  }

  public func register(inputSetProvider: InputSetProvider) {
    // no-op
  }

  open func actions(context: KeyboardContext) -> KeyboardActionRows {
    Self.actionRows
  }

  open func items(for actions: KeyboardActionRows, context: KeyboardContext) -> KeyboardLayoutItemRows {
    actions.enumerated().map { row in
      row.element.enumerated().map { action in
        item(for: action.element, row: row.offset, index: action.offset, context: context)
      }
    }
  }

  open func item(for action: KeyboardAction, row: Int, index: Int, context: KeyboardContext) -> KeyboardLayoutItem {
    let size = itemSize(for: action, row: row, index: index, context: context)
    let insets = Self.insets
    let swipes = itemSwipes(for: action, row: row, index: index, context: context)
    return KeyboardLayoutItem(action: action, size: size, insets: insets, swipes: swipes)
  }

  open func itemSize(for action: KeyboardAction, row: Int, index: Int, context: KeyboardContext) -> KeyboardLayoutItemSize {
    let width = itemSizeWidth(for: action, row: row, index: index, context: context)
    let height = itemSizeHeight(for: action, row: row, index: index, context: context)
    return KeyboardLayoutItemSize(width: width, height: height)
  }

  open func itemSizeWidth(for action: KeyboardAction, row: Int, index: Int, context: KeyboardContext) -> KeyboardLayoutItemWidth {
    switch action {
    case .character: return .input
    default: return .available
    }
  }

  open func itemSizeHeight(for action: KeyboardAction, row: Int, index: Int, context: KeyboardContext) -> CGFloat {
    let config = KeyboardLayoutConfiguration.standard(for: context)
    return config.rowHeight
  }

  open func itemInsets(for action: KeyboardAction, row: Int, index: Int, context: KeyboardContext) -> UIEdgeInsets {
    let config = KeyboardLayoutConfiguration.standard(for: context)
    switch action {
    case .characterMargin, .none: return .zero
    default: return config.buttonInsets
    }
  }

  open func itemSwipes(for action: KeyboardAction, row: Int, index: Int, context: KeyboardContext) -> [KeySwipe] {
    if let swipe = context.keyboardSwipe[context.keyboardType]?[action] {
      return swipe
    }
    return []
  }

  open func keyboardReturnAction(for context: KeyboardContext) -> KeyboardAction {
    let proxy = context.textDocumentProxy
    let returnType = proxy.returnKeyType?.keyboardReturnKeyType
    if let returnType { return .primary(returnType) }
    return .primary(.return)
  }

  /// Trailing actions applied to the second-to-last row.
  open func lowerTrailingActions(
    for actions: KeyboardActionRows,
    context: KeyboardContext
  ) -> KeyboardActions {
    return [keyboardReturnAction(for: context)]
  }

  /// Width of the small bottom keys (delete / confirm block).
  open func smallBottomWidth(for context: KeyboardContext) -> KeyboardLayoutItemWidth {
    .percentage(context.interfaceOrientation.isPortrait ? 0.165 : 0.135)
  }

  /// Width of the system keys on the bottom row.
  open func lowerSystemButtonWidth(for context: KeyboardContext) -> KeyboardLayoutItemWidth {
    return .percentage(0.13)
  }
}