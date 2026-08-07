import UIKit

// MARK: - ToolbarViewDelegate协议
protocol ToolbarViewDelegate: AnyObject {
    func toolbarDidTapLogo()
    func toolbarDidTapHelpReply()
    func toolbarDidTapSuperTalk()
    func toolbarDidTapMore()
    func toolbarDidTapContact()
    func toolbarDidTapPaste()
    func toolbarDidTapGenerate()

    // 语音输入（按住说话、松开转文字）
    func toolbarVoiceTouchDown()
    func toolbarVoiceTouchUpInside()
    func toolbarVoiceTouchCancel()
}

/// 工具栏视图 - 显示帮你回、超会说、AI恋爱回复等功能按钮
class ToolbarView: UIView {

    // MARK: - Delegate
    weak var delegate: ToolbarViewDelegate?

    // MARK: - UI组件
    private let stackView = UIStackView()
    private let logoButton = UIButton(type: .system)
    private let helpReplyButton = UIButton(type: .system)
    private let superTalkButton = UIButton(type: .system)
    private let contactButton = UIButton(type: .system)
    private let pasteButton = UIButton(type: .system)
    private let generateButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let voiceButton = UIButton(type: .system)

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
        backgroundColor = UIColor(white: 0.95, alpha: 1)

        // 配置StackView
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.spacing = 6
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])

        setupButtons()
    }

    private func setupButtons() {
        configureButton(logoButton, title: "Love", action: #selector(logoTapped))
        configureButton(helpReplyButton, title: "帮你回", action: #selector(helpReplyTapped))
        configureButton(superTalkButton, title: "超会说", action: #selector(superTalkTapped))
        configureButton(contactButton, title: "对象", action: #selector(contactTapped))
        configureButton(pasteButton, title: "粘贴", action: #selector(pasteTapped))
        configureButton(generateButton, title: "✨生成", action: #selector(generateTapped))
        configureButton(moreButton, title: "更多", action: #selector(moreTapped))
        setupVoiceButton()
    }

    /// 语音按钮：按住说话、松开转文字（不支持普通点击，避免误触发送）
    private func setupVoiceButton() {
        voiceButton.setTitle("语音", for: .normal)
        voiceButton.titleLabel?.font = .systemFont(ofSize: 13)
        voiceButton.titleLabel?.adjustsFontSizeToFitWidth = true
        voiceButton.titleLabel?.minimumScaleFactor = 0.8
        voiceButton.layer.cornerRadius = 8
        voiceButton.addTarget(self, action: #selector(voiceTouchDown), for: .touchDown)
        voiceButton.addTarget(self, action: #selector(voiceTouchUpInside), for: .touchUpInside)
        voiceButton.addTarget(self, action: #selector(voiceTouchCancel), for: [.touchUpOutside, .touchCancel])
        stackView.addArrangedSubview(voiceButton)
    }

    private func configureButton(_ button: UIButton, title: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.addTarget(self, action: action, for: .touchUpInside)
        stackView.addArrangedSubview(button)
    }

    // MARK: - 公共方法
    /// 更新对象按钮标题：选中联系人后显示联系人名，否则显示「对象」
    func setSelectedContactName(_ name: String?) {
        contactButton.setTitle(name ?? "对象", for: .normal)
    }

    /// 语音录音状态：录音中显示「松开发送」并高亮，否则恢复「语音」
    func setVoiceRecording(_ isRecording: Bool) {
        if isRecording {
            voiceButton.setTitle("松开发送", for: .normal)
            voiceButton.backgroundColor = UIColor.primaryPink.withAlphaComponent(0.25)
            voiceButton.setTitleColor(.systemRed, for: .normal)
        } else {
            voiceButton.setTitle("语音", for: .normal)
            voiceButton.backgroundColor = .clear
            voiceButton.setTitleColor(.systemBlue, for: .normal)
        }
    }

    // MARK: - 事件处理
    @objc private func logoTapped() {
        delegate?.toolbarDidTapLogo()
    }

    @objc private func helpReplyTapped() {
        delegate?.toolbarDidTapHelpReply()
    }

    @objc private func superTalkTapped() {
        delegate?.toolbarDidTapSuperTalk()
    }

    @objc private func contactTapped() {
        delegate?.toolbarDidTapContact()
    }

    @objc private func pasteTapped() {
        delegate?.toolbarDidTapPaste()
    }

    @objc private func generateTapped() {
        delegate?.toolbarDidTapGenerate()
    }

    @objc private func moreTapped() {
        delegate?.toolbarDidTapMore()
    }

    @objc private func voiceTouchDown() {
        delegate?.toolbarVoiceTouchDown()
    }

    @objc private func voiceTouchUpInside() {
        delegate?.toolbarVoiceTouchUpInside()
    }

    @objc private func voiceTouchCancel() {
        delegate?.toolbarVoiceTouchCancel()
    }
}
