//
//  NumericNineGridKeyboardLayoutProvider.swift
//
//
//  Created by morse on 2023/9/6.
//

import UIKit

/// 数字页布局（ClawTalk IOS原生，按文档）
/// 行1：1|2|3|4|删除
/// 行2：5|6|7|8|9
/// 行3：0|-|/|:|;
/// 行4：(|)|¥|@|更多
/// 行5：ABC|,|.|空格|发送/换行
open class NumericNineGridKeyboardLayoutProvider: KeyboardLayoutProvider {
  static let insets = UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)

  private let keyboardContext: KeyboardContext

  public var insets: UIEdgeInsets {
    Self.insets
  }

  init(keyboardContext: KeyboardContext) {
    self.keyboardContext = keyboardContext
  }

  public func keyboardLayout(for context: KeyboardContext) -> KeyboardLayout {
    let actions = self.actions(context: context)
    let items = self.items(for: actions, context: context)
    return KeyboardLayout(itemRows: items)
  }

  public func register(inputSetProvider: InputSetProvider) {
    // no-op
  }

  open func actions(context: KeyboardContext) -> KeyboardActionRows {
    [
      [.symbol(Symbol(char: "1")), .symbol(Symbol(char: "2")), .symbol(Symbol(char: "3")), .symbol(Symbol(char: "4")), .backspace],
      [.symbol(Symbol(char: "5")), .symbol(Symbol(char: "6")), .symbol(Symbol(char: "7")), .symbol(Symbol(char: "8")), .symbol(Symbol(char: "9"))],
      [.symbol(Symbol(char: "0")), .symbol(Symbol(char: "-")), .symbol(Symbol(char: "/")), .symbol(Symbol(char: ":")), .symbol(Symbol(char: ";"))],
      [.symbol(Symbol(char: "(")), .symbol(Symbol(char: ")")), .symbol(Symbol(char: "¥")), .symbol(Symbol(char: "@")), .keyboardType(.numericMoreSymbols)],
      [.keyboardType(.alphabetic(.lowercased)), .symbol(Symbol(char: ",")), .symbol(Symbol(char: ".")), .space, keyboardReturnAction(for: context)],
    ]
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

  open func smallBottomWidth(for context: KeyboardContext) -> KeyboardLayoutItemWidth {
    .percentage(keyboardContext.interfaceOrientation.isPortrait ? 0.165 : 0.135)
  }
}