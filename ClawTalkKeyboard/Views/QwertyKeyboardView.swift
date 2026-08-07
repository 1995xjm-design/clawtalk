import UIKit

// MARK: - QwertyKeyboardViewDelegate协议
protocol QwertyKeyboardViewDelegate: AnyObject {
    func qwertyKeyboardDidTapKey(_ key: String)
    func qwertyKeyboardDidTapDelete()
    func qwertyKeyboardDidTapSpace()
    func qwertyKeyboardDidTapReturn()
    func qwertyKeyboardDidTapShift()
    func qwertyKeyboardDidDoubleTapShift()
    func qwertyKeyboardDidTapLanguageSwitch()
    func qwertyKeyboardDidTapKeyboardSwitch()
    func qwertyKeyboardDidTapSymbol()
}

/// QWERTY键盘视图
class QwertyKeyboardView: UIView {

    // MARK: - Delegate
    weak var delegate: QwertyKeyboardViewDelegate?

    // MARK: - 状态
    private var isShifted = false
    private var isCapsLock = false
    private var inputMode: InputMode = .chinese
    private var lastShiftTapTime: Date?

    // MARK: - UI组件
    private var keyButtons: [[UIButton]] = []
    private var shiftButton: UIButton?
    private var deleteButton: UIButton?
    private var spaceButton: UIButton?
    private var returnButton: UIButton?
    private var symbolButton: UIButton?
    private var languageSwitchButton: UIButton?

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
        backgroundColor = UIColor(white: 0.85, alpha: 1)
        setupKeyboardRows()
    }

    private func setupKeyboardRows() {
        let rows = [
            ["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
            ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
            ["z", "x", "c", "v", "b", "n", "m"]
        ]

        let mainStack = UIStackView()
        mainStack.axis = .vertical
        mainStack.spacing = 8
        mainStack.distribution = .fillEqually
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])

        for (index, row) in rows.enumerated() {
            let rowStack = createRowStack(keys: row, rowIndex: index)
            mainStack.addArrangedSubview(rowStack)
        }

        let bottomRow = createBottomRow()
        mainStack.addArrangedSubview(bottomRow)
    }

    private func createRowStack(keys: [String], rowIndex: Int) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually

        var rowButtons: [UIButton] = []

        // 第三行添加Shift按钮
        if rowIndex == 2 {
            shiftButton = createSpecialButton(title: "⇧")
            shiftButton?.addTarget(self, action: #selector(shiftTapped), for: .touchUpInside)
            stack.addArrangedSubview(shiftButton!)
        }

        for key in keys {
            let button = createKeyButton(title: key)
            stack.addArrangedSubview(button)
            rowButtons.append(button)
        }

        // 第三行添加删除按钮
        if rowIndex == 2 {
            deleteButton = createSpecialButton(title: "⌫")
            deleteButton?.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
            stack.addArrangedSubview(deleteButton!)
        }

        keyButtons.append(rowButtons)
        return stack
    }

    private func createKeyButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 22)
        button.backgroundColor = .white
        button.layer.cornerRadius = 5
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowOpacity = 0.2
        button.layer.shadowRadius = 1
        button.addTarget(self, action: #selector(keyTapped(_:)), for: .touchUpInside)
        return button
    }

    private func createSpecialButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.backgroundColor = UIColor(white: 0.75, alpha: 1)
        button.layer.cornerRadius = 5
        return button
    }

    private func createBottomRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4

        // 符号按钮
        symbolButton = createSpecialButton(title: "123")
        symbolButton?.addTarget(self, action: #selector(symbolTapped), for: .touchUpInside)
        stack.addArrangedSubview(symbolButton!)

        // 语言切换按钮
        languageSwitchButton = createSpecialButton(title: "中/英")
        languageSwitchButton?.addTarget(self, action: #selector(languageSwitchTapped), for: .touchUpInside)
        stack.addArrangedSubview(languageSwitchButton!)

        // 空格按钮
        spaceButton = UIButton(type: .system)
        spaceButton?.setTitle("空格", for: .normal)
        spaceButton?.backgroundColor = .white
        spaceButton?.layer.cornerRadius = 5
        spaceButton?.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        stack.addArrangedSubview(spaceButton!)

        // 回车按钮
        returnButton = createSpecialButton(title: "换行")
        returnButton?.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        stack.addArrangedSubview(returnButton!)

        // 设置宽度比例
        symbolButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.12).isActive = true
        languageSwitchButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.12).isActive = true
        spaceButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.52).isActive = true
        returnButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.2).isActive = true

        return stack
    }

    // MARK: - 公共方法
    func updateInputMode(_ mode: InputMode) {
        inputMode = mode
        languageSwitchButton?.setTitle(mode == .chinese ? "中" : "英", for: .normal)
    }

    func updateShiftState(_ isShiftOn: Bool) {
        isShifted = isShiftOn
        updateKeyTitles()
        shiftButton?.backgroundColor = isShiftOn ? UIColor.primaryPink : UIColor(white: 0.75, alpha: 1)
    }

    func updateCapsLockState(_ isCapsLockOn: Bool) {
        isCapsLock = isCapsLockOn
        updateKeyTitles()
        shiftButton?.backgroundColor = isCapsLockOn ? UIColor.primaryPink : UIColor(white: 0.75, alpha: 1)
    }

    private func updateKeyTitles() {
        let shouldUppercase = isShifted || isCapsLock
        for row in keyButtons {
            for button in row {
                if let title = button.title(for: .normal) {
                    button.setTitle(shouldUppercase ? title.uppercased() : title.lowercased(), for: .normal)
                }
            }
        }
    }

    // MARK: - 事件处理
    @objc private func keyTapped(_ sender: UIButton) {
        guard let key = sender.title(for: .normal) else { return }
        delegate?.qwertyKeyboardDidTapKey(key)
    }

    @objc private func shiftTapped() {
        let now = Date()
        if let lastTap = lastShiftTapTime, now.timeIntervalSince(lastTap) < 0.3 {
            delegate?.qwertyKeyboardDidDoubleTapShift()
            lastShiftTapTime = nil
        } else {
            delegate?.qwertyKeyboardDidTapShift()
            lastShiftTapTime = now
        }
    }

    @objc private func deleteTapped() {
        delegate?.qwertyKeyboardDidTapDelete()
    }

    @objc private func spaceTapped() {
        delegate?.qwertyKeyboardDidTapSpace()
    }

    @objc private func returnTapped() {
        delegate?.qwertyKeyboardDidTapReturn()
    }

    @objc private func symbolTapped() {
        delegate?.qwertyKeyboardDidTapSymbol()
    }

    @objc private func languageSwitchTapped() {
        delegate?.qwertyKeyboardDidTapLanguageSwitch()
    }
}
