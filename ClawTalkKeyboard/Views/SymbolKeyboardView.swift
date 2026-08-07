import UIKit

// MARK: - SymbolKeyboardViewDelegate协议
protocol SymbolKeyboardViewDelegate: AnyObject {
    func symbolKeyboardDidTapSymbol(_ symbol: String)
    func symbolKeyboardDidTapBack()
    func symbolKeyboardDidTapDelete()
    func symbolKeyboardDidTapSpace()
    func symbolKeyboardDidTapReturn()
}

/// 符号键盘视图
class SymbolKeyboardView: UIView {

    // MARK: - Delegate
    weak var delegate: SymbolKeyboardViewDelegate?

    // MARK: - UI组件
    private var symbolButtons: [UIButton] = []
    private var backButton: UIButton?
    private var deleteButton: UIButton?
    private var spaceButton: UIButton?
    private var returnButton: UIButton?

    // 符号数据
    private let chineseSymbols = [
        ["，", "。", "？", "！", "、", "：", "；", "~"],
        ["（", "）", "【", "】", "《", "》", "「", "」"],
        ["@", "#", "%", "&", "*", "-", "+", "="]
    ]

    private let englishSymbols = [
        [",", ".", "?", "!", "'", "\"", ":", ";"],
        ["(", ")", "[", "]", "{", "}", "<", ">"],
        ["@", "#", "$", "%", "&", "*", "-", "+"]
    ]

    private var isChineseMode = true

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

        // 符号行
        let symbols = isChineseMode ? chineseSymbols : englishSymbols
        for row in symbols {
            let rowStack = createSymbolRow(symbols: row)
            mainStack.addArrangedSubview(rowStack)
        }

        // 底部功能行
        let bottomRow = createBottomRow()
        mainStack.addArrangedSubview(bottomRow)
    }

    private func createSymbolRow(symbols: [String]) -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        stack.distribution = .fillEqually

        for symbol in symbols {
            let button = createSymbolButton(title: symbol)
            stack.addArrangedSubview(button)
            symbolButtons.append(button)
        }

        return stack
    }

    private func createSymbolButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 20)
        button.backgroundColor = .white
        button.layer.cornerRadius = 5
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.layer.shadowOpacity = 0.2
        button.layer.shadowRadius = 1
        button.addTarget(self, action: #selector(symbolTapped(_:)), for: .touchUpInside)
        return button
    }

    private func createSpecialButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        button.backgroundColor = UIColor(white: 0.75, alpha: 1)
        button.layer.cornerRadius = 5
        return button
    }

    private func createBottomRow() -> UIStackView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4

        // 返回按钮
        backButton = createSpecialButton(title: "ABC")
        backButton?.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        stack.addArrangedSubview(backButton!)

        // 空格按钮
        spaceButton = UIButton(type: .system)
        spaceButton?.setTitle("空格", for: .normal)
        spaceButton?.backgroundColor = .white
        spaceButton?.layer.cornerRadius = 5
        spaceButton?.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        stack.addArrangedSubview(spaceButton!)

        // 删除按钮
        deleteButton = createSpecialButton(title: "⌫")
        deleteButton?.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        stack.addArrangedSubview(deleteButton!)

        // 回车按钮
        returnButton = createSpecialButton(title: "换行")
        returnButton?.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        stack.addArrangedSubview(returnButton!)

        // 设置宽度比例
        backButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.15).isActive = true
        spaceButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.45).isActive = true
        deleteButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.15).isActive = true
        returnButton?.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.2).isActive = true

        return stack
    }

    // MARK: - 公共方法
    func setChineseMode(_ isChinese: Bool) {
        isChineseMode = isChinese
        // 重新加载符号
        updateSymbols()
    }

    private func updateSymbols() {
        let symbols = isChineseMode ? chineseSymbols : englishSymbols
        var index = 0
        for row in symbols {
            for symbol in row {
                if index < symbolButtons.count {
                    symbolButtons[index].setTitle(symbol, for: .normal)
                }
                index += 1
            }
        }
    }

    // MARK: - 事件处理
    @objc private func symbolTapped(_ sender: UIButton) {
        guard let symbol = sender.title(for: .normal) else { return }
        delegate?.symbolKeyboardDidTapSymbol(symbol)
    }

    @objc private func backTapped() {
        delegate?.symbolKeyboardDidTapBack()
    }

    @objc private func deleteTapped() {
        delegate?.symbolKeyboardDidTapDelete()
    }

    @objc private func spaceTapped() {
        delegate?.symbolKeyboardDidTapSpace()
    }

    @objc private func returnTapped() {
        delegate?.symbolKeyboardDidTapReturn()
    }
}
