//
//  KeyboardColorRootView.swift
//  键盘配色页：系统默认 + 7 套主题（红/白/黑/黑金/海盐蓝/森林绿/樱花粉）8 选 1（互斥开关）
//  样式按 ClawTalk 红黑白主题 + 深浅色适配
//

import Combine
import HamsterUIKit
import HamsterKeyboardKit
import UIKit

private enum ClawTalkPalette {
  static let accentLight = UIColor(red: 183 / 255, green: 56 / 255, blue: 51 / 255, alpha: 1) // #B73833
  static let accentDark = UIColor(red: 198 / 255, green: 62 / 255, blue: 56 / 255, alpha: 1) // #C63E38
  static let voidLight = UIColor(red: 246 / 255, green: 247 / 255, blue: 249 / 255, alpha: 1) // #F6F7F9
  static let voidDark = UIColor(red: 11 / 255, green: 12 / 255, blue: 17 / 255, alpha: 1) // #0B0C11
  static let obsidianLight = UIColor.white
  static let obsidianDark = UIColor(red: 19 / 255, green: 21 / 255, blue: 28 / 255, alpha: 1) // #13151C

  static var accent: UIColor { adaptive(light: accentLight, dark: accentDark) }
  static var void: UIColor { adaptive(light: voidLight, dark: voidDark) }
  static var obsidian: UIColor { adaptive(light: obsidianLight, dark: obsidianDark) }

  static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { trait in trait.userInterfaceStyle == .dark ? dark : light }
  }
}

/// 配色选项行：标题 + 副标题 + 开关
class KeyboardColorOptionRow: UIView {
  let titleLabel = UILabel()
  let subtitleLabel = UILabel()
  let switchView = UISwitch()

  var onSwitchChanged: ((UISwitch) -> Void)?

  var isOn: Bool {
    get { switchView.isOn }
    set { switchView.isOn = newValue }
  }

  init(title: String, subtitle: String) {
    super.init(frame: .zero)

    titleLabel.text = title
    titleLabel.font = UIFont.preferredFont(forTextStyle: .body)
    titleLabel.textColor = .label

    subtitleLabel.text = subtitle
    subtitleLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
    subtitleLabel.textColor = .secondaryLabel

    switchView.onTintColor = ClawTalkPalette.accent
    switchView.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)

    let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    textStack.axis = .vertical
    textStack.alignment = .leading
    textStack.spacing = 2

    let row = UIStackView(arrangedSubviews: [textStack, switchView])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false

    addSubview(row)
    NSLayoutConstraint.activate([
      row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
    ])

    backgroundColor = ClawTalkPalette.obsidian
    layer.cornerRadius = 12
    layer.masksToBounds = true

    // 点击整行 = 选中该选项
    let tap = UITapGestureRecognizer(target: self, action: #selector(rowTapped))
    addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func switchChanged(_ sender: UISwitch) {
    onSwitchChanged?(sender)
  }

  @objc private func rowTapped() {
    if !isOn {
      switchView.setOn(true, animated: true)
      onSwitchChanged?(switchView)
    }
  }
}

class KeyboardColorRootView: NibLessView {
  private let keyboardColorViewModel: KeyboardColorViewModel

  private lazy var optionRows: [KeyboardColorOptionRow] = {
    var rows = [makeRow(title: "系统默认", subtitle: "苹果原生：跟随系统深浅色", index: 0)]
    for (offset, theme) in KeyboardColorViewModel.themeOptions.enumerated() {
      rows.append(makeRow(title: theme.displayName, subtitle: theme.displaySubtitle, index: offset + 1))
    }
    return rows
  }()

  private lazy var stackView: UIStackView = {
    let stack = UIStackView(arrangedSubviews: optionRows)
    stack.axis = .vertical
    stack.spacing = 10
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
  }()

  private lazy var footerLabel: UILabel = {
    let label = UILabel()
    label.text = "选择后自动应用到键盘配色，可随时在此切换。"
    label.font = UIFont.preferredFont(forTextStyle: .footnote)
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    label.translatesAutoresizingMaskIntoConstraints = false
    return label
  }()

  init(frame: CGRect = .zero, keyboardColorViewModel: KeyboardColorViewModel) {
    self.keyboardColorViewModel = keyboardColorViewModel
    super.init(frame: frame)
    setupSubview()
    syncSwitches()
  }

  private func makeRow(title: String, subtitle: String, index: Int) -> KeyboardColorOptionRow {
    let row = KeyboardColorOptionRow(title: title, subtitle: subtitle)
    row.switchView.tag = index
    row.onSwitchChanged = { [weak self] sender in
      self?.optionSwitchChanged(sender)
    }
    return row
  }

  private func setupSubview() {
    backgroundColor = ClawTalkPalette.void

    addSubview(stackView)
    addSubview(footerLabel)

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 16),
      stackView.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor, constant: 8),
      stackView.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor, constant: -8),

      footerLabel.topAnchor.constraint(equalTo: stackView.bottomAnchor, constant: 12),
      footerLabel.leadingAnchor.constraint(equalTo: stackView.leadingAnchor, constant: 4),
      footerLabel.trailingAnchor.constraint(equalTo: stackView.trailingAnchor, constant: -4),
    ])
  }

  private func optionSwitchChanged(_ sender: UISwitch) {
    // 开关互斥：只允许一个选项处于开启状态
    if sender.isOn {
      keyboardColorViewModel.selectedIndex = sender.tag
    } else {
      keyboardColorViewModel.selectedIndex = 0
    }
    syncSwitches()
  }

  private func syncSwitches() {
    let selected = keyboardColorViewModel.selectedIndex
    for (index, row) in optionRows.enumerated() {
      row.isOn = index == selected
    }
  }
}
