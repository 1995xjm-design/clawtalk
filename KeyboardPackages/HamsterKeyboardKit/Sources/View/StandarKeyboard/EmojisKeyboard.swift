//
//  EmojisKeyboard.swift
//
//
//  Created by morse on 2023/9/5.
//

import HamsterUIKit
import UIKit

/// Emojis 表情键盘：分类标签 + 表情网格 + 底部工具栏（返回键盘 / 删除）
class EmojisKeyboard: NibLessView {
  private let keyboardContext: KeyboardContext
  private let actionHandler: KeyboardActionHandler
  private let appearance: KeyboardAppearance

  /// 当前选中的分类
  private var selectedCategory: EmojiCategory = .frequent {
    didSet { reloadEmojis() }
  }

  /// 当前显示的 emoji 列表
  private var currentEmojis: [Emoji] = []

  /// 上次布局宽度，用于检测宽度变化时刷新 cell 尺寸
  private var lastLayoutWidth: CGFloat = 0

  // MARK: - Subviews

  private lazy var flowLayout: UICollectionViewFlowLayout = {
    let layout = UICollectionViewFlowLayout()
    layout.minimumInteritemSpacing = 4
    layout.minimumLineSpacing = 4
    layout.sectionInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    return layout
  }()

  private lazy var collectionView: UICollectionView = {
    let cv = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
    cv.translatesAutoresizingMaskIntoConstraints = false
    cv.backgroundColor = .clear
    cv.dataSource = self
    cv.delegate = self
    cv.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.id)
    cv.showsVerticalScrollIndicator = false
    return cv
  }()

  private lazy var categoryScrollView: UIScrollView = {
    let sv = UIScrollView()
    sv.translatesAutoresizingMaskIntoConstraints = false
    sv.showsHorizontalScrollIndicator = false
    sv.showsVerticalScrollIndicator = false
    sv.alwaysBounceHorizontal = true
    sv.delegate = self
    return sv
  }()

  private lazy var categoryBar: UIStackView = {
    let sv = UIStackView()
    sv.axis = .horizontal
    sv.distribution = .fillEqually
    sv.spacing = 0
    sv.translatesAutoresizingMaskIntoConstraints = false
    return sv
  }()

  private lazy var bottomBar: UIView = {
    let v = UIView()
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  private lazy var deleteButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "delete.left"), for: .normal)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
    return btn
  }()

  /// TAB_BACK：返回来源面板（emoji_prev_panel）
  private lazy var backButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.translatesAutoresizingMaskIntoConstraints = false
    btn.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
    return btn
  }()

  // MARK: - Init

  init(keyboardContext: KeyboardContext, actionHandler: KeyboardActionHandler, appearance: KeyboardAppearance) {
    self.keyboardContext = keyboardContext
    self.actionHandler = actionHandler
    self.appearance = appearance
    super.init(frame: .zero)
    setupView()
    reloadEmojis()
  }

  // MARK: - Setup

  private func setupView() {
    let style = appearance.candidateBarStyle
    backgroundColor = appearance.backgroundStyle.backgroundColor

    addSubview(categoryScrollView)
    addSubview(collectionView)
    addSubview(bottomBar)
    categoryScrollView.addSubview(categoryBar)
    bottomBar.addSubview(backButton)
    bottomBar.addSubview(deleteButton)

    // 构建分类按钮
    for category in EmojiCategory.allCases {
      let btn = UIButton(type: .system)
      btn.setTitle(category.fallbackDisplayEmoji.char, for: .normal)
      btn.titleLabel?.font = .systemFont(ofSize: 20)
      btn.tag = EmojiCategory.allCases.firstIndex(of: category) ?? 0
      btn.addTarget(self, action: #selector(categoryTapped(_:)), for: .touchUpInside)
      categoryBar.addArrangedSubview(btn)
    }
    updateCategoryHighlight()

    backButton.setTitle(backButtonTitle, for: .normal)
    backButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    backButton.setTitleColor(style.toolbarButtonFrontColor, for: .normal)
    styleCapsule(backButton)

    deleteButton.tintColor = style.toolbarButtonFrontColor
    styleCapsule(deleteButton)

    NSLayoutConstraint.activate([
      categoryScrollView.topAnchor.constraint(equalTo: topAnchor),
      categoryScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      categoryScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      categoryScrollView.heightAnchor.constraint(equalToConstant: 36),

      categoryBar.topAnchor.constraint(equalTo: categoryScrollView.topAnchor),
      categoryBar.bottomAnchor.constraint(equalTo: categoryScrollView.bottomAnchor),
      categoryBar.leadingAnchor.constraint(equalTo: categoryScrollView.leadingAnchor),
      categoryBar.widthAnchor.constraint(equalToConstant: 48 * CGFloat(EmojiCategory.allCases.count)),

      collectionView.topAnchor.constraint(equalTo: categoryBar.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
      collectionView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

      bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
      bottomBar.heightAnchor.constraint(equalToConstant: 40),

      backButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 12),
      backButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
      backButton.widthAnchor.constraint(equalToConstant: 46),
      backButton.heightAnchor.constraint(equalToConstant: 32),

      deleteButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -12),
      deleteButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
      deleteButton.widthAnchor.constraint(equalToConstant: 42),
      deleteButton.heightAnchor.constraint(equalToConstant: 32),
    ])
  }

  /// 胶囊底样式
  private func styleCapsule(_ button: UIButton) {
    button.backgroundColor = .secondarySystemFill
    button.layer.cornerRadius = 16
    button.layer.masksToBounds = true
  }

  // MARK: - Layout

  override var intrinsicContentSize: CGSize {
    // 与标准键盘高度保持一致：4 行按键的高度
    let config = KeyboardLayoutConfiguration.standard(for: keyboardContext)
    let rowHeight = config.rowHeight
    let rows: CGFloat = 4
    return CGSize(width: UIView.noIntrinsicMetric, height: rowHeight * rows)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if bounds.width != lastLayoutWidth && bounds.width > 0 {
      lastLayoutWidth = bounds.width
      flowLayout.invalidateLayout()
    }
  }

  // MARK: - Data

  private func reloadEmojis() {
    currentEmojis = selectedCategory.emojis
    collectionView.reloadData()
    if !currentEmojis.isEmpty {
      collectionView.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
    }
    updateCategoryHighlight()
  }

  private func updateCategoryHighlight() {
    let selectedIndex = EmojiCategory.allCases.firstIndex(of: selectedCategory) ?? 0
    for (i, view) in categoryBar.arrangedSubviews.enumerated() {
      view.alpha = i == selectedIndex ? 1.0 : 0.4
    }
  }

  // MARK: - Actions

  @objc private func categoryTapped(_ sender: UIButton) {
    let index = sender.tag
    guard index < EmojiCategory.allCases.count else { return }
    selectedCategory = EmojiCategory.allCases[index]
    let offsetX = CGFloat(index) * 48 - (categoryScrollView.bounds.width - 48) / 2
    let clamped = min(max(offsetX, 0), categoryScrollView.contentSize.width - categoryScrollView.bounds.width)
    categoryScrollView.setContentOffset(CGPoint(x: max(clamped, 0), y: 0), animated: true)
  }

  @objc private func deleteTapped() {
    keyboardContext.textDocumentProxy.deleteBackward()
  }

  /// 返回键标题：按来源面板显示（英文=ABC / 数字=123 / 中文=中）
  private var backButtonTitle: String {
    switch keyboardContext.clawEmojiPrevPanel {
    case .alphabetic: return "ABC"
    case .numericNineGrid, .englishNumeric: return "123"
    case .numericMoreSymbols: return "更多"
    default: return "中"
    }
  }

  /// TAB_BACK：退出 emoji 回来源面板（不写死回 9 键主页）
  @objc private func backTapped() {
    let prev = keyboardContext.clawEmojiPrevPanel ?? .chineseNineGridIOS
    keyboardContext.clawEmojiPrevPanel = nil
    keyboardContext.setKeyboardType(prev)
  }
}

// MARK: - UICollectionViewDataSource

extension EmojisKeyboard: UICollectionViewDataSource {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    currentEmojis.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.id, for: indexPath) as! EmojiCell
    cell.configure(with: currentEmojis[indexPath.item])
    return cell
  }
}

// MARK: - UICollectionViewDelegate

extension EmojisKeyboard: UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let emoji = currentEmojis[indexPath.item]
    keyboardContext.textDocumentProxy.insertText(emoji.char)
    EmojiCategory.frequentEmojiProvider.registerEmoji(emoji)
  }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension EmojisKeyboard: UICollectionViewDelegateFlowLayout {
  func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
    let columns: CGFloat = 8
    let spacing: CGFloat = 4
    let insets: CGFloat = 16 // 8 left + 8 right
    let availableWidth = collectionView.bounds.width - insets - spacing * (columns - 1)
    guard availableWidth > 0 else { return CGSize(width: 36, height: 36) }
    let width = floor(availableWidth / columns)
    return CGSize(width: width, height: width)
  }
}

// MARK: - Emoji Cell

private class EmojiCell: UICollectionViewCell {
  static let id = "EmojiCell"

  private let label: UILabel = {
    let l = UILabel()
    l.font = .systemFont(ofSize: 28)
    l.textAlignment = .center
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }()

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  func configure(with emoji: Emoji) {
    label.text = emoji.char
  }

  override var isHighlighted: Bool {
    didSet {
      contentView.backgroundColor = isHighlighted ? UIColor.systemGray4 : .clear
      contentView.layer.cornerRadius = 8
    }
  }
}

// MARK: - UIScrollViewDelegate

extension EmojisKeyboard: UIScrollViewDelegate {
  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView == categoryScrollView,
          categoryScrollView.isDragging || categoryScrollView.isDecelerating
    else { return }
    let itemWidth: CGFloat = 48
    let idx = Int(round(scrollView.contentOffset.x / itemWidth))
    let clamped = min(max(idx, 0), EmojiCategory.allCases.count - 1)
    let target = EmojiCategory.allCases[clamped]
    if target != selectedCategory {
      selectedCategory = target
    }
  }
}
