//
//  NumericNineGridKeyboard.swift
//
//
//  Created by morse on 2023/9/5.
//

import HamsterKit
import HamsterUIKit
import UIKit

/// 数字页（ClawTalk IOS原生）
/// 行1：1|2|3|4|删除
/// 行2：5|6|7|8|9
/// 行3：0|-|/|:|;
/// 行4：(|)|¥|@|#+=
/// 行5：ABC|,|.|空格|确认
public class NumericNineGridKeyboard: KeyboardTouchView {
  // MARK: - Properties

  private let keyboardLayoutProvider: NumericNineGridKeyboardLayoutProvider
  private let actionHandler: KeyboardActionHandler
  private let appearance: KeyboardAppearance
  private var keyboardContext: KeyboardContext
  private var calloutContext: KeyboardCalloutContext
  private var rimeContext: RimeContext

  private var interfaceOrientation: InterfaceOrientation

  private var userInterfaceStyle: UIUserInterfaceStyle

  private var isKeyboardFloating: Bool

  /// 缓存所有按键视图
  private var keyboardRows: [[KeyboardButton]] = []

  private var staticConstraints: [NSLayoutConstraint] = []

  private var dynamicConstraints: [NSLayoutConstraint] = []

  // MARK: - 计算属性

  private var layout: KeyboardLayout {
    keyboardLayoutProvider.keyboardLayout(for: keyboardContext)
  }

  private var layoutConfig: KeyboardLayoutConfiguration {
    .standard(for: keyboardContext)
  }

  // MARK: - Initialization

  init(
    actionHandler: KeyboardActionHandler,
    appearance: KeyboardAppearance,
    keyboardContext: KeyboardContext,
    calloutContext: KeyboardCalloutContext,
    rimeContext: RimeContext
  ) {
    self.keyboardLayoutProvider = NumericNineGridKeyboardLayoutProvider(keyboardContext: keyboardContext)
    self.actionHandler = actionHandler
    self.appearance = appearance
    self.keyboardContext = keyboardContext
    self.calloutContext = calloutContext
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

  override public func constructViewHierarchy() {
    // 添加按键
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
          calloutContext: calloutContext,
          appearance: appearance
        )
        buttonItem.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonItem)
        tempRow.append(buttonItem)
      }
      keyboardRows.append(tempRow)
    }
  }

  override public func activateViewConstraints() {
    let rowHeight = layoutConfig.rowHeight

    let engine = ClawNineGridLayoutEngine(
      rowHeight: rowHeight,
      specs: [
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1]),
        .equal([0: 1, 1: 1, 2: 1, 3: 1, 4: 1]),
        .equal([0: 1, 1: 1, 2: 1, 3: 1, 4: 1]),
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 1]),
        .fixed([4: 0.165], equal: [0: 1, 1: 1, 2: 1, 3: 2]),
      ]
    )
    engine.build(on: self, rows: keyboardRows)

    staticConstraints = engine.staticConstraints
    dynamicConstraints = engine.dynamicHeightConstraints
  }

  override public func layoutSubviews() {
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