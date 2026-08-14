//
//  ClassifySymbolicKeyboard.swift
//
//
//  Created by morse on 2023/9/5.
//

import HamsterUIKit
import UIKit

/// 扩展符号页（ClawTalk IOS原生）
/// 行1：[|]|{|}|删除
/// 行2：#|%|^|*|+
/// 行3：=|\||~|<
/// 行4：>|€|£|¥|123
/// 行5：ABC|,|.|空格|确认
class ClassifySymbolicKeyboard: KeyboardTouchView {
  private let keyboardContext: KeyboardContext
  private let actionHandler: KeyboardActionHandler
  private let appearance: KeyboardAppearance
  private let rimeContext: RimeContext

  private var interfaceOrientation: InterfaceOrientation
  private var userInterfaceStyle: UIUserInterfaceStyle
  private var isKeyboardFloating: Bool

  private var keyboardRows: [[KeyboardButton]] = []
  private var staticConstraints: [NSLayoutConstraint] = []
  private var dynamicConstraints: [NSLayoutConstraint] = []

  // MARK: - 计算属性

  private var layoutConfig: KeyboardLayoutConfiguration {
    .standard(for: keyboardContext)
  }

  private var actionRows: KeyboardActionRows {
    [
      [.symbol(Symbol(char: "[")), .symbol(Symbol(char: "]")), .symbol(Symbol(char: "{")), .symbol(Symbol(char: "}")), .backspace],
      [.symbol(Symbol(char: "#")), .symbol(Symbol(char: "%")), .symbol(Symbol(char: "^")), .symbol(Symbol(char: "*")), .symbol(Symbol(char: "+"))],
      [.symbol(Symbol(char: "=")), .symbol(Symbol(char: "|")), .symbol(Symbol(char: "~")), .symbol(Symbol(char: "<"))],
      [.symbol(Symbol(char: ">")), .symbol(Symbol(char: "€")), .symbol(Symbol(char: "£")), .symbol(Symbol(char: "¥")), .keyboardType(.numericNineGrid)],
      [.keyboardType(.chineseNineGrid), .symbol(Symbol(char: ",")), .symbol(Symbol(char: ".")), .space, .primary(.custom(title: "确认"))],
    ]
  }

  private var layout: KeyboardLayout {
    let items = actionRows.enumerated().map { row -> KeyboardLayoutItemRow in
      row.element.enumerated().map { action -> KeyboardLayoutItem in
        KeyboardLayoutItem(
          action: action.element,
          size: KeyboardLayoutItemSize(width: .available, height: layoutConfig.rowHeight),
          insets: UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3),
          swipes: []
        )
      }
    }
    return KeyboardLayout(itemRows: items)
  }

  // MARK: - Initailization

  init(
    actionHandler: KeyboardActionHandler,
    appearance: KeyboardAppearance,
    layoutProvider: KeyboardLayoutProvider,
    keyboardContext: KeyboardContext,
    rimeContext: RimeContext
  ) {
    self.actionHandler = actionHandler
    self.appearance = appearance
    self.keyboardContext = keyboardContext
    self.rimeContext = rimeContext
    self.interfaceOrientation = keyboardContext.interfaceOrientation
    self.isKeyboardFloating = keyboardContext.isKeyboardFloating
    self.userInterfaceStyle = keyboardContext.colorScheme

    super.init(frame: .zero)

    setupKeyboardView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Layout

  func setupKeyboardView() {
    backgroundColor = ClawIOSNativePalette.keyboardBackground

    constructViewHierarchy()
    activateViewConstraints()
  }

  override func constructViewHierarchy() {
    for (rowIndex, row) in layout.itemRows.enumerated() {
      var tempRow = [KeyboardButton]()
      for (itemIndex, item) in row.enumerated() {
        let buttonItem = KeyboardButton(
          row: rowIndex,
          column: itemIndex,
          item: item,
          actionHandler: actionHandler,
          keyboardContext: keyboardContext,
          rimeContext: rimeContext,
          calloutContext: .disabled,
          appearance: appearance
        )
        buttonItem.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonItem)
        tempRow.append(buttonItem)
      }
      keyboardRows.append(tempRow)
    }
  }

  override func activateViewConstraints() {
    let rowHeight = layoutConfig.rowHeight

    let engine = ClawNineGridLayoutEngine(
      rowHeight: rowHeight,
      specs: [
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1]),
        .equal([0: 1, 1: 1, 2: 1, 3: 1, 4: 1]),
        .equal([0: 1, 1: 1, 2: 1, 3: 1]),
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1]),
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 2]),
      ]
    )
    engine.build(on: self, rows: keyboardRows)

    staticConstraints = engine.staticConstraints
    dynamicConstraints = engine.dynamicHeightConstraints
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    if userInterfaceStyle != keyboardContext.colorScheme {
      userInterfaceStyle = keyboardContext.colorScheme
      keyboardRows.forEach { $0.forEach { $0.setNeedsLayout() } }
    }

    guard interfaceOrientation != keyboardContext.interfaceOrientation || isKeyboardFloating != keyboardContext.isKeyboardFloating else { return }
    interfaceOrientation = keyboardContext.interfaceOrientation
    isKeyboardFloating = keyboardContext.isKeyboardFloating

    let rowHeight = layoutConfig.rowHeight
    dynamicConstraints.forEach {
      $0.constant = rowHeight
    }
  }
}