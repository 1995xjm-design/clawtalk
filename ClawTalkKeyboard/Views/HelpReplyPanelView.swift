import UIKit

// MARK: - HelpReplyPanelViewDelegate协议
protocol HelpReplyPanelViewDelegate: AnyObject {
    func helpReplyPanelDidTapClose()
    func helpReplyPanelDidTapPaste() -> String?
    func helpReplyPanelDidSelectReply(_ text: String)
    func helpReplyPanelDidTapContact()
}

/// AI恋爱回复结果面板 - 输入对方的话，展示3~5条AI回复气泡
class HelpReplyPanelView: UIView {

    // MARK: - Delegate
    weak var delegate: HelpReplyPanelViewDelegate?

    // MARK: - UI组件
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    private let contactLabel = UILabel()
    private let inputTextView = UITextView()
    private let inputHintLabel = UILabel()
    private let resultScrollView = UIScrollView()
    private let repliesStackView = UIStackView()
    private let placeholderLabel = UILabel()
    private let loadingStackView = UIStackView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private var replies: [String] = []

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
        setupResultArea()
        reset()
    }

    private func setupHeader() {
        // 关闭按钮
        closeButton.setTitle("×", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 24)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // 标题
        titleLabel.text = "AI 恋爱回复"
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 粘贴按钮
        pasteButton.setTitle("粘贴", for: .normal)
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pasteButton)

        // 对象标签（点击弹出对象选择列表）
        contactLabel.text = "对象：未选择 ▾"
        contactLabel.font = .systemFont(ofSize: 13)
        contactLabel.textColor = .systemPink
        contactLabel.isUserInteractionEnabled = true
        contactLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contactLabel)
        let contactTap = UITapGestureRecognizer(target: self, action: #selector(contactTapped))
        contactLabel.addGestureRecognizer(contactTap)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            pasteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pasteButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            contactLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contactLabel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 2)
        ])
    }

    private func setupInputArea() {
        inputTextView.font = .systemFont(ofSize: 15)
        inputTextView.layer.borderColor = UIColor.lightGray.cgColor
        inputTextView.layer.borderWidth = 1
        inputTextView.layer.cornerRadius = 8
        inputTextView.delegate = self
        inputTextView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputTextView)

        // 输入区占位提示
        inputHintLabel.text = "粘贴或输入对方的话…"
        inputHintLabel.font = .systemFont(ofSize: 14)
        inputHintLabel.textColor = .lightGray
        inputHintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inputHintLabel)

        NSLayoutConstraint.activate([
            inputTextView.topAnchor.constraint(equalTo: contactLabel.bottomAnchor, constant: 6),
            inputTextView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            inputTextView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            inputTextView.heightAnchor.constraint(equalToConstant: 56),

            inputHintLabel.leadingAnchor.constraint(equalTo: inputTextView.leadingAnchor, constant: 6),
            inputHintLabel.topAnchor.constraint(equalTo: inputTextView.topAnchor, constant: 8)
        ])
    }

    private func setupResultArea() {
        // 结果滚动区
        resultScrollView.showsVerticalScrollIndicator = false
        resultScrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultScrollView)

        repliesStackView.axis = .vertical
        repliesStackView.spacing = 8
        repliesStackView.translatesAutoresizingMaskIntoConstraints = false
        resultScrollView.addSubview(repliesStackView)

        NSLayoutConstraint.activate([
            resultScrollView.topAnchor.constraint(equalTo: inputTextView.bottomAnchor, constant: 10),
            resultScrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            resultScrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            resultScrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            repliesStackView.leadingAnchor.constraint(equalTo: resultScrollView.contentLayoutGuide.leadingAnchor),
            repliesStackView.trailingAnchor.constraint(equalTo: resultScrollView.contentLayoutGuide.trailingAnchor),
            repliesStackView.topAnchor.constraint(equalTo: resultScrollView.contentLayoutGuide.topAnchor),
            repliesStackView.bottomAnchor.constraint(equalTo: resultScrollView.contentLayoutGuide.bottomAnchor),
            repliesStackView.widthAnchor.constraint(equalTo: resultScrollView.widthAnchor)
        ])

        // 未生成时的步骤提示
        placeholderLabel.text = "① 点【对象】选择聊天对象\n② 粘贴或输入对方的话\n③ 点工具栏 ✨ 生成 AI 回复"
        placeholderLabel.font = .systemFont(ofSize: 14)
        placeholderLabel.textColor = .lightGray
        placeholderLabel.textAlignment = .center
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)

        // 生成中loading
        loadingStackView.axis = .horizontal
        loadingStackView.spacing = 8
        loadingStackView.alignment = .center
        loadingStackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingStackView)

        activityIndicator.startAnimating()
        loadingStackView.addArrangedSubview(activityIndicator)

        loadingLabel.text = "正在分析对方画像…"
        loadingLabel.font = .systemFont(ofSize: 14)
        loadingLabel.textColor = .gray
        loadingStackView.addArrangedSubview(loadingLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: resultScrollView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: resultScrollView.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: resultScrollView.leadingAnchor, constant: 16),
            placeholderLabel.trailingAnchor.constraint(equalTo: resultScrollView.trailingAnchor, constant: -16),

            loadingStackView.centerXAnchor.constraint(equalTo: resultScrollView.centerXAnchor),
            loadingStackView.centerYAnchor.constraint(equalTo: resultScrollView.centerYAnchor)
        ])
    }

    private func createReplyBubble(_ text: String) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor(white: 0.95, alpha: 1)
        container.layer.cornerRadius = 10
        container.clipsToBounds = true

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15)
        label.textColor = .darkText
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(replyBubbleTapped(_:)))
        container.addGestureRecognizer(tap)
        return container
    }

    // MARK: - 公共方法
    func reset() {
        inputTextView.text = ""
        updateInputHint()
        replies = []
        resultScrollView.isHidden = false
        placeholderLabel.isHidden = false
        loadingStackView.isHidden = true
        repliesStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    func setInputText(_ text: String) {
        inputTextView.text = text
        updateInputHint()
    }

    func getInputText() -> String {
        return inputTextView.text ?? ""
    }

    func setContactName(_ name: String?) {
        if let name = name, !name.isEmpty {
            contactLabel.text = "对象：\(name) ▾"
        } else {
            contactLabel.text = "对象：未选择 ▾"
        }
    }

    /// 生成中loading状态
    func setLoading(_ loading: Bool) {
        if loading {
            placeholderLabel.isHidden = true
            resultScrollView.isHidden = false
            loadingStackView.isHidden = false
        } else if replies.isEmpty {
            resultScrollView.isHidden = false
            placeholderLabel.isHidden = false
            loadingStackView.isHidden = true
        } else {
            placeholderLabel.isHidden = true
            resultScrollView.isHidden = false
            loadingStackView.isHidden = true
        }
    }

    /// 展示AI回复气泡
    func setReplies(_ replies: [String]) {
        self.replies = replies
        repliesStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for reply in replies {
            repliesStackView.addArrangedSubview(createReplyBubble(reply))
        }
        placeholderLabel.isHidden = true
        loadingStackView.isHidden = true
        resultScrollView.isHidden = false
    }

    private func updateInputHint() {
        inputHintLabel.isHidden = !(inputTextView.text ?? "").isEmpty
    }

    // MARK: - 事件处理
    @objc private func closeTapped() {
        delegate?.helpReplyPanelDidTapClose()
    }

    @objc private func pasteTapped() {
        if let text = delegate?.helpReplyPanelDidTapPaste() {
            inputTextView.text = text
            updateInputHint()
        }
    }

    @objc private func contactTapped() {
        delegate?.helpReplyPanelDidTapContact()
    }

    @objc private func replyBubbleTapped(_ gesture: UITapGestureRecognizer) {
        guard let container = gesture.view,
              let index = repliesStackView.arrangedSubviews.firstIndex(of: container),
              index < replies.count else { return }
        delegate?.helpReplyPanelDidSelectReply(replies[index])
    }
}

// MARK: - UITextViewDelegate
extension HelpReplyPanelView: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        updateInputHint()
    }
}