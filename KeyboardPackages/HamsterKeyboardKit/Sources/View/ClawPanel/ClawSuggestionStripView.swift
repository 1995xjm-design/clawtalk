import UIKit

/// 实时建议条：竖向芯片列表（可滚动），点击=直接发出，长按=复制
public final class ClawSuggestionStripView: UIView {
  /// 点击建议：直接发出
  public var onSend: ((String) -> Void)?
  /// 长按建议：复制到剪贴板
  public var onCopy: ((String) -> Void)?

  private let scrollView = UIScrollView()
  private let stackView = UIStackView()

  public override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = false
    addSubview(scrollView)

    stackView.axis = .vertical
    stackView.spacing = 6
    stackView.alignment = .fill
    stackView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
      stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])
  }

  /// 刷新建议列表
  public func update(suggestions: [String]) {
    stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for text in suggestions {
      let chip = makeChip(text: text)
      stackView.addArrangedSubview(chip)
    }
    isHidden = suggestions.isEmpty
  }

  private func makeChip(text: String) -> UIView {
    let chip = UIView()
    chip.backgroundColor = ClawPanelPalette.capsuleNormal
    chip.layer.cornerRadius = 12
    chip.layer.borderWidth = 1
    chip.layer.borderColor = ClawPanelPalette.brandBlue.withAlphaComponent(0.35).cgColor
    chip.layer.masksToBounds = true

    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 12, weight: .medium)
    label.textColor = ClawPanelPalette.candidateText
    label.numberOfLines = 2
    label.translatesAutoresizingMaskIntoConstraints = false
    chip.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 5),
      label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -5),
      label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
    ])

    let tap = UITapGestureRecognizer(target: self, action: #selector(chipTapped(_:)))
    chip.addGestureRecognizer(tap)
    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(chipLongPressed(_:)))
    longPress.minimumPressDuration = 0.5
    chip.addGestureRecognizer(longPress)
    chip.tag = stackView.arrangedSubviews.count
    return chip
  }

  @objc private func chipTapped(_ sender: UITapGestureRecognizer) {
    guard let chip = sender.view else { return }
    onSend?(chipText(for: chip))
  }

  @objc private func chipLongPressed(_ sender: UILongPressGestureRecognizer) {
    guard sender.state == .began, let chip = sender.view else { return }
    onCopy?(chipText(for: chip))
  }

  private func chipText(for chip: UIView) -> String {
    chip.subviews.compactMap { $0 as? UILabel }.first?.text ?? ""
  }
}

/// AI 按钮毛玻璃风格（ClawTalk 红系 / 圆角 / 毛玻璃）
public final class ClawGlassButton: UIButton {
  private let tintView = UIView()
  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))

  /// 玻璃底色调（主题强调色）
  public var glassTintColor: UIColor = .clear {
    didSet { tintView.backgroundColor = glassTintColor }
  }

  public override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    tintView.isUserInteractionEnabled = false
    blurView.isUserInteractionEnabled = false
    addSubview(blurView)
    addSubview(tintView)
    blurView.translatesAutoresizingMaskIntoConstraints = false
    tintView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      tintView.topAnchor.constraint(equalTo: topAnchor),
      tintView.bottomAnchor.constraint(equalTo: bottomAnchor),
      tintView.leadingAnchor.constraint(equalTo: leadingAnchor),
      tintView.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
    // 底色在下、毛玻璃在上，文字（titleLabel）在最上层
    sendSubviewToBack(tintView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
