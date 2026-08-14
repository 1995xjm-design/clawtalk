//
//  CandidateWordsView.swift
//
//
//  Created by morse on 2023/8/19.
//

import Combine
import HamsterKit
import HamsterUIKit
import UIKit

/**
 候选栏视图（ClawTalk IOS原生）

 支持两种形态：
 - 双层（仅中文九宫格主页面）：第 1 层拼音行（44pt，只放拼音候选，禁放业务按钮）+ 第 2 层汉字行（44pt，横向滚动，内嵌业务按钮）
 - 单层（数字页 / 扩展符号页 / 英文 T9 页 / 表情页）：单行候选
 最右侧为收起箭头（#86868B）+ 下拉（收起键盘）按钮。
 */
public class CandidateBarView: NibLessView {
  /// 候选区状态
  public enum State {
    /// 展开
    case expand
    /// 收起
    case collapse

    func isCollapse() -> Bool {
      return self == .collapse
    }
  }

  private var style: CandidateBarStyle
  private var actionHandler: KeyboardActionHandler
  private var keyboardContext: KeyboardContext
  private var rimeContext: RimeContext
  private var subscriptions = Set<AnyCancellable>()

  /// 拼音行（仅中文主页双层模式第 1 层）：数据源 = Rime 拼音候选
  lazy var pinyinRowView: PinyinCandidateRowView = {
    let view = PinyinCandidateRowView(rimeContext: rimeContext)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// 汉字行容器（仅中文主页双层模式第 2 层）：内嵌业务按钮 + 汉字候选横向滚动
  lazy var hanziRowView: UIView = {
    let view = UIView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    return view
  }()

  /// 业务按钮容器：中文主页汉字行内嵌（由工具栏注入 AI / 超会说 / 眼睛）
  var businessButtonContainer: UIView? {
    didSet {
      guard let container = businessButtonContainer else { return }
      if container.superview !== hanziRowView {
        hanziRowView.addSubview(container)
        NSLayoutConstraint.activate([
          container.leadingAnchor.constraint(equalTo: hanziRowView.leadingAnchor, constant: 8),
          container.centerYAnchor.constraint(equalTo: hanziRowView.centerYAnchor),
          container.heightAnchor.constraint(equalToConstant: 36),
        ])
      }
      rebuildLayout()
    }
  }

  /// 滚动分页的候选文字区域
  lazy var candidatesArea: CandidateWordsCollectionView = {
    let view = CandidateWordsCollectionView(
      style: style,
      keyboardContext: keyboardContext,
      actionHandler: actionHandler,
      rimeContext: rimeContext)
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// 手动分页的候选文字区域（遗留，不再使用）
  lazy var candidatesPagingArea: CandidatesPagingCollectionView = {
    let view = CandidatesPagingCollectionView(
      style: style,
      keyboardContext: keyboardContext,
      actionHandler: actionHandler,
      rimeContext: rimeContext)
    view.backgroundColor = .clear
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// 状态图片视图（收起箭头）
  lazy var stateImageView: UIImageView = {
    let view = UIImageView(frame: .zero)
    view.contentMode = .center
    view.translatesAutoresizingMaskIntoConstraints = false
    view.image = stateImage(.collapse)
    return view
  }()

  /// 竖线
  lazy var verticalLine: UIView = {
    let view = UIView(frame: .zero)
    view.backgroundColor = ClawIOSNativePalette.collapseArrow.withAlphaComponent(0.3)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  /// 候选区展开或收起控制按钮
  lazy var controlStateView: UIView = {
    let view = UIView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    view.addSubview(stateImageView)
    view.addSubview(verticalLine)

    NSLayoutConstraint.activate([
      verticalLine.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
      view.bottomAnchor.constraint(equalTo: verticalLine.bottomAnchor, constant: 3),
      view.leadingAnchor.constraint(equalTo: verticalLine.leadingAnchor),
      verticalLine.widthAnchor.constraint(equalToConstant: 1),

      stateImageView.leadingAnchor.constraint(equalTo: verticalLine.trailingAnchor),
      stateImageView.topAnchor.constraint(equalTo: view.topAnchor),
      stateImageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stateImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
    ])

    // 添加状态控制
    view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(changeState)))
    return view
  }()

  /// 下拉按钮（收起键盘）：候选栏最右侧
  lazy var dismissKeyboardButton: UIButton = {
    let button = UIButton(type: .system)
    button.setImage(UIImage(systemName: "chevron.down.circle"), for: .normal)
    button.setPreferredSymbolConfiguration(.init(font: .systemFont(ofSize: 17), scale: .default), forImageIn: .normal)
    button.tintColor = ClawIOSNativePalette.collapseArrow
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: #selector(dismissTapped), for: .touchUpInside)
    return button
  }()

  /// 右侧控制列（收起箭头 + 下拉按钮）
  lazy var controlColumn: UIView = {
    let view = UIView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = .clear
    view.addSubview(controlStateView)
    if keyboardContext.displayKeyboardDismissButton {
      view.addSubview(dismissKeyboardButton)
    }
    return view
  }()

  // MARK: - 布局状态

  /// 是否双层模式（中文九宫格主页面）
  private var isDoubleMode: Bool {
    keyboardContext.keyboardType.isChineseNineGrid
  }

  private var doubleConstraints: [NSLayoutConstraint] = []
  private var singleConstraints: [NSLayoutConstraint] = []
  private var expandedConstraints: [NSLayoutConstraint] = []

  // MARK: - 计算属性

  /// 布局配置
  private var layoutConfig: KeyboardLayoutConfiguration {
    .standard(for: keyboardContext)
  }

  init(style: CandidateBarStyle, actionHandler: KeyboardActionHandler, keyboardContext: KeyboardContext, rimeContext: RimeContext) {
    self.style = style
    self.actionHandler = actionHandler
    self.keyboardContext = keyboardContext
    self.rimeContext = rimeContext

    super.init(frame: .zero)

    setupContentView()

    combine()
  }

  func setupContentView() {
    constructViewHierarchy()
    activateViewConstraints()
    setupAppearance()
  }

  /// 构建视图层次
  override public func constructViewHierarchy() {
    addSubview(pinyinRowView)
    addSubview(hanziRowView)
    addSubview(candidatesArea)
    addSubview(candidatesPagingArea)
    addSubview(controlColumn)
  }

  /// 激活静态约束
  override public func activateViewConstraints() {
    let buttonInsets = layoutConfig.buttonInsets

    NSLayoutConstraint.activate([
      // 拼音行：双层模式第 1 层（44pt）
      pinyinRowView.topAnchor.constraint(equalTo: topAnchor),
      pinyinRowView.leadingAnchor.constraint(equalTo: leadingAnchor),
      pinyinRowView.trailingAnchor.constraint(equalTo: trailingAnchor),
      pinyinRowView.heightAnchor.constraint(equalToConstant: ClawIOSNativePalette.candidateRowHeight),

      // 汉字行：双层模式第 2 层（44pt）
      hanziRowView.topAnchor.constraint(equalTo: pinyinRowView.bottomAnchor),
      hanziRowView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hanziRowView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hanziRowView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // 右侧控制列（收起箭头 + 下拉）
      controlColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
      controlColumn.topAnchor.constraint(equalTo: topAnchor),
      controlColumn.bottomAnchor.constraint(equalTo: bottomAnchor),
      controlColumn.widthAnchor.constraint(equalToConstant: 40),

      controlStateView.topAnchor.constraint(equalTo: controlColumn.topAnchor),
      controlStateView.centerXAnchor.constraint(equalTo: controlColumn.centerXAnchor),
      controlStateView.widthAnchor.constraint(equalTo: controlColumn.widthAnchor),
      controlStateView.heightAnchor.constraint(equalTo: controlStateView.widthAnchor),

      candidatesPagingArea.topAnchor.constraint(equalTo: topAnchor),
      candidatesPagingArea.bottomAnchor.constraint(equalTo: bottomAnchor),
      candidatesPagingArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: buttonInsets.left),
      candidatesPagingArea.trailingAnchor.constraint(equalTo: controlColumn.leadingAnchor),
    ])

    if keyboardContext.displayKeyboardDismissButton {
      NSLayoutConstraint.activate([
        dismissKeyboardButton.topAnchor.constraint(equalTo: controlStateView.bottomAnchor),
        dismissKeyboardButton.centerXAnchor.constraint(equalTo: controlColumn.centerXAnchor),
        dismissKeyboardButton.widthAnchor.constraint(equalTo: controlColumn.widthAnchor),
        dismissKeyboardButton.bottomAnchor.constraint(equalTo: controlColumn.bottomAnchor),
      ])
    }

    rebuildLayout()
  }

  /// 根据当前形态重建候选区约束
  func rebuildLayout() {
    NSLayoutConstraint.deactivate(doubleConstraints + singleConstraints + expandedConstraints)
    doubleConstraints.removeAll(keepingCapacity: true)
    singleConstraints.removeAll(keepingCapacity: true)
    expandedConstraints.removeAll(keepingCapacity: true)

    // 展开态：候选区纵向铺满整个候选栏
    expandedConstraints = [
      candidatesArea.topAnchor.constraint(equalTo: topAnchor),
      candidatesArea.bottomAnchor.constraint(equalTo: bottomAnchor),
      candidatesArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      candidatesArea.trailingAnchor.constraint(equalTo: controlColumn.leadingAnchor),
    ]

    if isDoubleMode {
      let leadingAnchor = businessButtonContainer?.trailingAnchor ?? hanziRowView.leadingAnchor
      let leadingConstant: CGFloat = businessButtonContainer != nil ? 6 : 8
      doubleConstraints = [
        candidatesArea.topAnchor.constraint(equalTo: hanziRowView.topAnchor),
        candidatesArea.bottomAnchor.constraint(equalTo: hanziRowView.bottomAnchor),
        candidatesArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingConstant),
        candidatesArea.trailingAnchor.constraint(equalTo: controlColumn.leadingAnchor),
      ]
    } else {
      singleConstraints = [
        candidatesArea.topAnchor.constraint(equalTo: topAnchor),
        candidatesArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        candidatesArea.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
        candidatesArea.trailingAnchor.constraint(equalTo: controlColumn.leadingAnchor),
      ]
    }

    // 显隐切换
    let isExpanded = !keyboardContext.candidatesViewState.isCollapse()
    pinyinRowView.isHidden = isExpanded || !isDoubleMode
    hanziRowView.isHidden = isExpanded || !isDoubleMode
    businessButtonContainer?.isHidden = isExpanded || !isDoubleMode
    candidatesPagingArea.isHidden = true

    if isExpanded {
      NSLayoutConstraint.activate(expandedConstraints)
    } else if isDoubleMode {
      NSLayoutConstraint.activate(doubleConstraints)
    } else {
      NSLayoutConstraint.activate(singleConstraints)
    }
  }

  override public func setupAppearance() {
    // 候选栏背景：全局写死 #F1F1F3
    backgroundColor = ClawIOSNativePalette.candidateBarBackground

    // 收起箭头：全局写死 #86868B
    stateImageView.tintColor = ClawIOSNativePalette.collapseArrow

    // 候选文字样式：全局写死（候选 #111111 / 选中 #007AFF）
    style = ClawIOSNativePalette.candidateBarStyle
    candidatesArea.setupStyle(style)
    candidatesPagingArea.setupStyle(style)
  }

  func setStyle(_ style: CandidateBarStyle) {
    self.style = style
    setupAppearance()
  }

  @objc func changeState() {
    let state: State = keyboardContext.candidatesViewState.isCollapse() ? .expand : .collapse
    stateImageView.image = stateImage(state)
    verticalLine.isHidden = state == .expand
    keyboardContext.candidatesViewState = state
  }

  @objc func dismissTapped() {
    actionHandler.handle(.release, on: .dismissKeyboard)
  }

  // 状态图片
  func stateImage(_ state: State) -> UIImage? {
    let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .default)
    return state == .collapse
      ? UIImage(systemName: "chevron.down", withConfiguration: config)
      : UIImage(systemName: "chevron.up", withConfiguration: config)
  }

  func combine() {
    // 键盘类型切换（中文主页双层 ↔ 其他单层）
    keyboardContext.keyboardTypePublished
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.rebuildLayout()
      }
      .store(in: &subscriptions)

    // 候选区展开/收起：重建布局
    keyboardContext.$candidatesViewState
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self = self else { return }
        self.rebuildLayout()
      }
      .store(in: &subscriptions)
  }
}