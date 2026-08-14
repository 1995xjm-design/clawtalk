//
//  ChineseNineGridIOS.swift
//
//
//  Created by morse on 2023/9/5.
//

import Combine
import HamsterKit
import HamsterUIKit
import OSLog
import UIKit

/// 中文九宫格键盘（ClawTalk IOS原生，按文档）
/// 行1：123 | ,。？！ | ABC | DEF | 删除
/// 行2：#@¥ | GHI | JKL | MNO
/// 行3：ABC | PQRS | TUV | WXYZ
/// 行4：😀表情 58 | 选拼音 58 | 空格 163 | 发送/换行
public class ChineseNineGridIOSKeyboard: KeyboardTouchView {
  // MARK: - Properties

  private let keyboardLayoutProvider: ChineseNineGridLayoutProvider
  private let actionHandler: KeyboardActionHandler
  private let appearance: KeyboardAppearance
  private var keyboardContext: KeyboardContext
  private var calloutContext: KeyboardCalloutContext
  private var rimeContext: RimeContext

  // 屏幕方向
  private var interfaceOrientation: InterfaceOrientation

  private var userInterfaceStyle: UIUserInterfaceStyle

  // 键盘是否浮动
  private var isKeyboardFloating: Bool

  /// 缓存所有按键视图
  private var keyboardRows: [[KeyboardButton]] = []

  /// 静态视图约束
  private var staticConstraints: [NSLayoutConstraint] = []

  private var dynamicHeightConstraints: [NSLayoutConstraint] = []

  // combine
  private var subscriptions = Set<AnyCancellable>()

  // MARK: - 计算属性

  private var layout: KeyboardLayout {
    keyboardLayoutProvider.keyboardLayout(for: keyboardContext)
  }

  private var layoutConfig: KeyboardLayoutConfiguration {
    .standard(for: keyboardContext)
  }

  // MARK: - Initialization

  public init(
    keyboardLayoutProvider: KeyboardLayoutProvider,
    actionHandler: KeyboardActionHandler,
    appearance: KeyboardAppearance,
    keyboardContext: KeyboardContext,
    calloutContext: KeyboardCalloutContext,
    rimeContext: RimeContext
  ) {
    if let keyboardLayoutProvider = keyboardLayoutProvider as? StandardKeyboardLayoutProvider {
      self.keyboardLayoutProvider = keyboardLayoutProvider.chineseNineGridLayoutProvider
    } else {
      self.keyboardLayoutProvider = ChineseNineGridLayoutProvider()
    }
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

    combine()
  }

  func combine() {
    // 屏幕方向改变重新计算动态高度
    keyboardContext.$interfaceOrientation
      .receive(on: DispatchQueue.main)
      .sink { [unowned self] in
        guard interfaceOrientation != $0 else { return }
        setNeedsUpdateConstraints()
      }
      .store(in: &subscriptions)
  }

  // MARK: - Layout

  func setupKeyboardView() {
    backgroundColor = ClawIOSNativePalette.colors(for: keyboardContext.colorScheme).keyboardBackground

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
        .equal([0: 1, 1: 1, 2: 1, 3: 1]),
        .equal([0: 1, 1: 1, 2: 1, 3: 1]),
        .fixedPt([0: 58, 1: 58, 2: 163], equal: [3: 1]),
      ]
    )
    engine.build(on: self, rows: keyboardRows)

    staticConstraints = engine.staticConstraints
    dynamicHeightConstraints = engine.dynamicHeightConstraints
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    // 样式调整
    if userInterfaceStyle != keyboardContext.colorScheme {
      userInterfaceStyle = keyboardContext.colorScheme
      backgroundColor = ClawIOSNativePalette.colors(for: userInterfaceStyle).keyboardBackground
      keyboardRows.forEach { $0.forEach { $0.setNeedsLayout() } }
    }

    // 行高调整
    guard interfaceOrientation != keyboardContext.interfaceOrientation || isKeyboardFloating != keyboardContext.isKeyboardFloating else { return }
    interfaceOrientation = keyboardContext.interfaceOrientation
    isKeyboardFloating = keyboardContext.isKeyboardFloating

    let rowHeight = layoutConfig.rowHeight
    dynamicHeightConstraints.forEach {
      $0.constant = rowHeight
    }
  }
}
