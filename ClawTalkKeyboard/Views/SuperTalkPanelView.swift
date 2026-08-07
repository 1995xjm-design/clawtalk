import UIKit

// MARK: - SuperTalkPanelViewDelegate协议
protocol SuperTalkPanelViewDelegate: AnyObject {
    func superTalkPanelDidTapClose()
    func superTalkPanelDidTapKey(_ key: String)
    func superTalkPanelDidTapDelete()
    func superTalkPanelDidTapSpace()
    func superTalkPanelDidSelectCandidate(_ candidate: String)
    func superTalkPanelDidTapCursorLeft()
    func superTalkPanelDidTapCursorRight()
    func superTalkPanelDidSelectResult(_ text: String)
    func superTalkPanelGetInputContent() -> String
}

/// 超会说面板视图
class SuperTalkPanelView: UIView {

    // MARK: - Delegate
    weak var delegate: SuperTalkPanelViewDelegate?

    // MARK: - UI组件
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let inputLabel = UILabel()
    private let candidateScrollView = UIScrollView()
    private let candidateStackView = UIStackView()
    private let cursorLeftButton = UIButton(type: .system)
    private let cursorRightButton = UIButton(type: .system)
    private var keyboardView: UIView!
    private var resultButtons: [UIButton] = []

    // 情话模板
    private let loveTemplates = [
        "早上好，今天也要开心哦",
        "晚安，好梦",
        "我爱你，永远爱你",
        "想你了，你在干嘛",
        "吃饭了吗？记得按时吃饭",
        "天冷了，多穿点衣服",
        "工作顺利吗？加油哦",
        "今天辛苦了，好好休息"
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
        setupInputArea()
        setupCandidateBar()
        setupKeyboard()
        setupResultArea()
    }

    private func setupHeader() {
        // 关闭按钮
        closeButton.setTitle("×", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 24)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // 标题
        titleLabel.text = "超会说"
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

    private func setupInputArea() {
        // 输入显示区域
        inputLabel.font = .systemFont(ofSize: 16)
        inputLabel.textAlignment = .center
        inputLabel.backgroundColor = UIColor(white: 0.95, alpha: 1)
        inputLabel.layer.cornerRadius = 8
        inputLabel.clipsToBounds = true
        inputLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputLabel)

        // 光标左移按钮
        cursorLeftButton.setTitle("<", for: .normal)
        cursorLeftButton.addTarget(self, action: #selector(cursorLeftTapped), for: .touchUpInside)
        cursorLeftButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cursorLeftButton)

        // 光标右移按钮
        cursorRightButton.setTitle(">", for: .normal)
        cursorRightButton.addTarget(self, action: #selector(cursorRightTapped), for: .touchUpInside)
        cursorRightButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cursorRightButton)

        NSLayoutConstraint.activate([
            cursorLeftButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            cursorLeftButton.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            cursorLeftButton.widthAnchor.constraint(equalToConstant: 40),
            cursorLeftButton.heightAnchor.constraint(equalToConstant: 36),

            inputLabel.leadingAnchor.constraint(equalTo: cursorLeftButton.trailingAnchor, constant: 4),
            inputLabel.trailingAnchor.constraint(equalTo: cursorRightButton.leadingAnchor, constant: -4),
            inputLabel.centerYAnchor.constraint(equalTo: cursorLeftButton.centerYAnchor),
            inputLabel.heightAnchor.constraint(equalToConstant: 36),

            cursorRightButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cursorRightButton.centerYAnchor.constraint(equalTo: cursorLeftButton.centerYAnchor),
            cursorRightButton.widthAnchor.constraint(equalToConstant: 40),
            cursorRightButton.heightAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func setupCandidateBar() {
        candidateScrollView.showsHorizontalScrollIndicator = false
        candidateScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(candidateScrollView)

        candidateStackView.axis = .horizontal
        candidateStackView.spacing = 12
        candidateStackView.translatesAutoresizingMaskIntoConstraints = false
        candidateScrollView.addSubview(candidateStackView)

        NSLayoutConstraint.activate([
            candidateScrollView.topAnchor.constraint(equalTo: inputLabel.bottomAnchor, constant: 8),
            candidateScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            candidateScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            candidateScrollView.heightAnchor.constraint(equalToConstant: 36),

            candidateStackView.leadingAnchor.constraint(equalTo: candidateScrollView.leadingAnchor, constant: 8),
            candidateStackView.trailingAnchor.constraint(equalTo: candidateScrollView.trailingAnchor, constant: -8),
            candidateStackView.centerYAnchor.constraint(equalTo: candidateScrollView.centerYAnchor)
        ])
    }

    private func setupKeyboard() {
        keyboardView = UIView()
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keyboardView)

        NSLayoutConstraint.activate([
            keyboardView.topAnchor.constraint(equalTo: candidateScrollView.bottomAnchor, constant: 8),
            keyboardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            keyboardView.heightAnchor.constraint(equalToConstant: 120)
        ])

        // 简化键盘 - 只显示常用按键
        let rows = [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m", "⌫"]
        ]

        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.spacing = 4
        mainStack.distribution = .fillEqually
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        keyboardView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: keyboardView.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: keyboardView.leadingAnchor, constant: 4),
            mainStack.trailingAnchor.constraint(equalTo: keyboardView.trailingAnchor, constant: -4),
            mainStack.bottomAnchor.constraint(equalTo: keyboardView.bottomAnchor)
        ])

        for row in rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 4
            rowStack.distribution = .fillEqually

            for key in row {
                let button = UIButton(type: .system)
                button.setTitle(key, for: .normal)
                button.backgroundColor = key == "⌫" ? UIColor(white: 0.75, alpha: 1) : .white
                button.layer.cornerRadius = 5
                if key == "⌫" {
                    button.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
                } else {
                    button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
                }
                rowStack.addArrangedSubview(button)
            }

            mainStack.addArrangedSubview(rowStack)
        }

        // 空格行
        let spaceRow = UIStackView()
        spaceRow.axis = .horizontal
        spaceRow.spacing = 4

        let spaceButton = UIButton(type: .system)
        spaceButton.setTitle("空格", for: .normal)
        spaceButton.backgroundColor = .white
        spaceButton.layer.cornerRadius = 5
        spaceButton.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        spaceRow.addArrangedSubview(spaceButton)

        mainStack.addArrangedSubview(spaceRow)
    }

    private func setupResultArea() {
        let resultStack = UIStackView()
        resultStack.axis = .vertical
        resultStack.spacing = 4
        resultStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultStack)

        NSLayoutConstraint.activate([
            resultStack.topAnchor.constraint(equalTo: keyboardView.bottomAnchor, constant: 8),
            resultStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            resultStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            resultStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])

        // 显示情话模板
        for i in stride(from: 0, to: loveTemplates.count, by: 2) {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 8
            rowStack.distribution = .fillEqually

            for j in i..<min(i + 2, loveTemplates.count) {
                let button = createResultButton(title: loveTemplates[j])
                rowStack.addArrangedSubview(button)
                resultButtons.append(button)
            }

            resultStack.addArrangedSubview(rowStack)
        }
    }

    private func createResultButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 12)
        button.titleLabel?.numberOfLines = 1
        button.backgroundColor = UIColor(white: 0.95, alpha: 1)
        button.layer.cornerRadius = 5
        button.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        button.addTarget(self, action: #selector(resultTapped(_:)), for: .touchUpInside)
        return button
    }

    // MARK: - 公共方法
    func reset() {
        inputLabel.text = ""
        candidateStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func updateInputContent(_ content: String, cursorPosition: Int) {
        // 显示带光标的内容
        if cursorPosition >= 0 && cursorPosition <= content.count {
            let index = content.index(content.startIndex, offsetBy: cursorPosition)
            let before = String(content[..<index])
            let after = String(content[index...])
            inputLabel.text = before + "|" + after
        } else {
            inputLabel.text = content
        }
    }

    func updateCandidates(_ candidates: [String], pinyin: String) {
        candidateStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for candidate in candidates {
            let button = UIButton(type: .system)
            button.setTitle(candidate, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16)
            button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
            candidateStackView.addArrangedSubview(button)
        }
    }

    // MARK: - 事件处理
    @objc private func closeTapped() {
        delegate?.superTalkPanelDidTapClose()
    }

    @objc private func keyTapped(_ sender: UIButton) {
        guard let key = sender.title(for: .normal) else { return }
        delegate?.superTalkPanelDidTapKey(key)
    }

    @objc private func deleteTapped() {
        delegate?.superTalkPanelDidTapDelete()
    }

    @objc private func spaceTapped() {
        delegate?.superTalkPanelDidTapSpace()
    }

    @objc private func candidateTapped(_ sender: UIButton) {
        guard let candidate = sender.title(for: .normal) else { return }
        delegate?.superTalkPanelDidSelectCandidate(candidate)
    }

    @objc private func cursorLeftTapped() {
        delegate?.superTalkPanelDidTapCursorLeft()
    }

    @objc private func cursorRightTapped() {
        delegate?.superTalkPanelDidTapCursorRight()
    }

    @objc private func resultTapped(_ sender: UIButton) {
        guard let text = sender.title(for: .normal) else { return }
        delegate?.superTalkPanelDidSelectResult(text)
    }
}
