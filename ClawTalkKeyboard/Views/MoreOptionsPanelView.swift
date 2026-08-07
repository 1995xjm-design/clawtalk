import UIKit

// MARK: - MoreOptionsPanelViewDelegate协议
protocol MoreOptionsPanelViewDelegate: AnyObject {
    func moreOptionsPanelDidTapClose()
    func moreOptionsPanelDidSelectKeyboardType(_ type: KeyboardType)
}

/// 更多选项面板视图
class MoreOptionsPanelView: UIView {

    // MARK: - Delegate
    weak var delegate: MoreOptionsPanelViewDelegate?

    // MARK: - UI组件
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var optionButtons: [UIButton] = []

    // 键盘类型选项
    private let keyboardOptions: [(title: String, type: KeyboardType)] = [
        ("26键", .qwerty),
        ("9键", .t9),
        ("手写", .handwriting)
    ]

    // MARK: - 初始化
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    // MARK: - UI设置
    private func setupUI() {
        backgroundColor = .white

        setupHeader()
        setupKeyboardOptions()
        setupOtherOptions()
    }

    private func setupHeader() {
        // 关闭按钮
        closeButton.setTitle("×", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 24)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // 标题
        titleLabel.text = "更多"
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
        ])
    }

    private func setupKeyboardOptions() {
        let sectionLabel = UILabel()
        sectionLabel.text = "键盘类型"
        sectionLabel.font = .systemFont(ofSize: 14)
        sectionLabel.textColor = .gray
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionLabel)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            sectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            stack.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 44)
        ])

        for option in keyboardOptions {
            let button = createOptionButton(title: option.title)
            button.tag = option.type.rawValue
            button.addTarget(self, action: #selector(keyboardTypeTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
            optionButtons.append(button)
        }
    }

    private func setupOtherOptions() {
        let sectionLabel = UILabel()
        sectionLabel.text = "其他功能"
        sectionLabel.font = .systemFont(ofSize: 14)
        sectionLabel.textColor = .gray
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionLabel)

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            sectionLabel.topAnchor.constraint(equalTo: optionButtons.first?.superview?.bottomAnchor ?? closeButton.bottomAnchor, constant: 16),
            sectionLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),

            stack.topAnchor.constraint(equalTo: sectionLabel.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.heightAnchor.constraint(equalToConstant: 44)
        ])

        let otherOptions = ["设置", "表情", "剪贴板"]
        for option in otherOptions {
            let button = createOptionButton(title: option)
            button.addTarget(self, action: #selector(otherOptionTapped(_:)), for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
    }

    private func createOptionButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.backgroundColor = UIColor(white: 0.95, alpha: 1)
        button.layer.cornerRadius = 8
        return button
    }

    // MARK: - 公共方法
    func updateSelectedKeyboardType(_ type: KeyboardType) {
        for button in optionButtons {
            if button.tag == type.rawValue {
                button.backgroundColor = UIColor.primaryPink.withAlphaComponent(0.2)
                button.setTitleColor(UIColor.primaryPink, for: .normal)
            } else {
                button.backgroundColor = UIColor(white: 0.95, alpha: 1)
                button.setTitleColor(.systemBlue, for: .normal)
            }
        }
    }

    // MARK: - 事件处理
    @objc private func closeTapped() {
        delegate?.moreOptionsPanelDidTapClose()
    }

    @objc private func keyboardTypeTapped(_ sender: UIButton) {
        guard let type = KeyboardType(rawValue: sender.tag) else { return }
        delegate?.moreOptionsPanelDidSelectKeyboardType(type)
    }

    @objc private func otherOptionTapped(_ sender: UIButton) {
        // 其他选项暂时只关闭面板
        delegate?.moreOptionsPanelDidTapClose()
    }
}
