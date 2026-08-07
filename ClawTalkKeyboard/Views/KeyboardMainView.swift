import UIKit

// MARK: - 键盘主视图代理协议
protocol KeyboardMainViewDelegate: AnyObject {
    func didTapKey(_ key: String)
    func didTapDelete()
    func didTapSpace()
    func didTapReturn()
    func didTapShift()
    func didDoubleTapShift()
    func didTapLanguageSwitch()
    func didTapKeyboardSwitch()
    func didTapSymbol()
    func didTapNumber()
    func didSelectCandidate(_ candidate: String, source: CandidateSource)
    func didTapHelpReply()
    func didTapSuperTalk()
    func didTapMore()
    func didTapConfig()
    func didTapContact()
    func didTapPaste()
    func didTapGenerate()
    func didSelectContact(_ contact: ChatContact)
    func didTapBackToKeyboard()
    func didTapPunctuation(_ punctuation: String)
    func didRequestPaste() -> String?
    func didRequestSendText(_ text: String)

    // 超会说专用
    func didTapKeyForSuperTalk(_ key: String)
    func didTapDeleteForSuperTalk()
    func didTapSpaceForSuperTalk()
    func didSelectCandidateForSuperTalk(_ candidate: String)
    func moveCursorLeft()
    func moveCursorRight()
    func getSuperTalkInputContent() -> String
}

// MARK: - 键盘主视图
class KeyboardMainView: UIView {

    weak var delegate: KeyboardMainViewDelegate?

    // MARK: - Subviews
    private var toolbarView: ToolbarView!
    private var candidateBarView: CandidateBarView!
    private var qwertyKeyboardView: QwertyKeyboardView!
    private var symbolKeyboardView: SymbolKeyboardView!
    private var helpReplyPanelView: HelpReplyPanelView!
    private var superTalkPanelView: SuperTalkPanelView!
    private var moreOptionsPanelView: MoreOptionsPanelView!
    private var configPanelView: ConfigPanelView!
    private var contactPopupOverlay: UIButton!
    private var contactPopupContainer: UIView!
    private var contactPopupStack: UIStackView!
    private var cachedContacts: [ChatContact] = []

    private var currentKeyboardType: KeyboardType = .qwerty
    private var inputMode: InputMode = .chinese

    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    // MARK: - Setup
    private func setupViews() {
        backgroundColor = UIColor(hex: "D1D4DB")

        setupToolbar()
        setupCandidateBar()
        setupKeyboards()
        setupPanels()
        setupContactPopup()
    }

    private func setupToolbar() {
        toolbarView = ToolbarView()
        toolbarView.delegate = self
        toolbarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarView)

        NSLayoutConstraint.activate([
            toolbarView.topAnchor.constraint(equalTo: topAnchor),
            toolbarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarView.heightAnchor.constraint(equalToConstant: KeyboardLayout.toolbarHeight)
        ])
    }

    private func setupCandidateBar() {
        candidateBarView = CandidateBarView()
        candidateBarView.delegate = self
        candidateBarView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(candidateBarView)

        NSLayoutConstraint.activate([
            candidateBarView.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            candidateBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            candidateBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            candidateBarView.heightAnchor.constraint(equalToConstant: KeyboardLayout.candidateBarHeight)
        ])
    }

    private func setupKeyboards() {
        // QWERTY键盘
        qwertyKeyboardView = QwertyKeyboardView()
        qwertyKeyboardView.delegate = self
        qwertyKeyboardView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(qwertyKeyboardView)

        NSLayoutConstraint.activate([
            qwertyKeyboardView.topAnchor.constraint(equalTo: candidateBarView.bottomAnchor),
            qwertyKeyboardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            qwertyKeyboardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            qwertyKeyboardView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 符号键盘
        symbolKeyboardView = SymbolKeyboardView()
        symbolKeyboardView.delegate = self
        symbolKeyboardView.translatesAutoresizingMaskIntoConstraints = false
        symbolKeyboardView.isHidden = true
        addSubview(symbolKeyboardView)

        NSLayoutConstraint.activate([
            symbolKeyboardView.topAnchor.constraint(equalTo: candidateBarView.bottomAnchor),
            symbolKeyboardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            symbolKeyboardView.trailingAnchor.constraint(equalTo: trailingAnchor),
            symbolKeyboardView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func setupPanels() {
        // 帮你回面板
        helpReplyPanelView = HelpReplyPanelView()
        helpReplyPanelView.delegate = self
        helpReplyPanelView.translatesAutoresizingMaskIntoConstraints = false
        helpReplyPanelView.isHidden = true
        addSubview(helpReplyPanelView)

        NSLayoutConstraint.activate([
            helpReplyPanelView.topAnchor.constraint(equalTo: candidateBarView.bottomAnchor),
            helpReplyPanelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            helpReplyPanelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            helpReplyPanelView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 超会说面板
        superTalkPanelView = SuperTalkPanelView()
        superTalkPanelView.delegate = self
        superTalkPanelView.translatesAutoresizingMaskIntoConstraints = false
        superTalkPanelView.isHidden = true
        addSubview(superTalkPanelView)

        NSLayoutConstraint.activate([
            superTalkPanelView.topAnchor.constraint(equalTo: topAnchor),
            superTalkPanelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            superTalkPanelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            superTalkPanelView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 更多选项面板
        moreOptionsPanelView = MoreOptionsPanelView()
        moreOptionsPanelView.delegate = self
        moreOptionsPanelView.translatesAutoresizingMaskIntoConstraints = false
        moreOptionsPanelView.isHidden = true
        addSubview(moreOptionsPanelView)

        NSLayoutConstraint.activate([
            moreOptionsPanelView.topAnchor.constraint(equalTo: topAnchor),
            moreOptionsPanelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            moreOptionsPanelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            moreOptionsPanelView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // 网关配置面板（键盘独立配置，绕过 App Group）
        configPanelView = ConfigPanelView()
        configPanelView.delegate = self
        configPanelView.translatesAutoresizingMaskIntoConstraints = false
        configPanelView.isHidden = true
        addSubview(configPanelView)

        NSLayoutConstraint.activate([
            configPanelView.topAnchor.constraint(equalTo: topAnchor),
            configPanelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            configPanelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            configPanelView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    // MARK: - Public Methods
    func updateKeyboardType(_ type: KeyboardType) {
        currentKeyboardType = type

        qwertyKeyboardView.isHidden = type != .qwerty
        symbolKeyboardView.isHidden = type != .symbol
    }

    func updateInputMode(_ mode: InputMode) {
        inputMode = mode
        qwertyKeyboardView.updateInputMode(mode)
    }

    func updateShiftState(_ isShiftOn: Bool) {
        qwertyKeyboardView.updateShiftState(isShiftOn)
    }

    func updateCapsLockState(_ isCapsLockOn: Bool) {
        qwertyKeyboardView.updateCapsLockState(isCapsLockOn)
    }

    func updateCandidates(_ candidates: [String], pinyin: String) {
        candidateBarView.updateCandidates(candidates, pinyin: pinyin)
    }

    func showKeyboard() {
        toolbarView.isHidden = false
        candidateBarView.isHidden = false
        qwertyKeyboardView.isHidden = currentKeyboardType != .qwerty
        symbolKeyboardView.isHidden = currentKeyboardType != .symbol
        helpReplyPanelView.isHidden = true
        superTalkPanelView.isHidden = true
        moreOptionsPanelView.isHidden = true
        configPanelView.isHidden = true

        hideContactPopup()
    }

    func showHelpReplyPanel() {
        toolbarView.isHidden = false
        candidateBarView.isHidden = false
        qwertyKeyboardView.isHidden = true
        symbolKeyboardView.isHidden = true
        helpReplyPanelView.isHidden = false
        superTalkPanelView.isHidden = true
        moreOptionsPanelView.isHidden = true
        configPanelView.isHidden = true

        hideContactPopup()
        helpReplyPanelView.reset()
    }

    func showSuperTalkPanel() {
        toolbarView.isHidden = true
        candidateBarView.isHidden = true
        qwertyKeyboardView.isHidden = true
        symbolKeyboardView.isHidden = true
        helpReplyPanelView.isHidden = true
        superTalkPanelView.isHidden = false
        moreOptionsPanelView.isHidden = true
        configPanelView.isHidden = true

        hideContactPopup()
        superTalkPanelView.reset()
    }

    func showMoreOptionsPanel() {
        toolbarView.isHidden = true
        candidateBarView.isHidden = true
        qwertyKeyboardView.isHidden = true
        symbolKeyboardView.isHidden = true
        helpReplyPanelView.isHidden = true
        superTalkPanelView.isHidden = true
        moreOptionsPanelView.isHidden = false
        configPanelView.isHidden = true

        hideContactPopup()
    }

    func showConfigPanel() {
        toolbarView.isHidden = true
        candidateBarView.isHidden = true
        qwertyKeyboardView.isHidden = true
        symbolKeyboardView.isHidden = true
        helpReplyPanelView.isHidden = true
        superTalkPanelView.isHidden = true
        moreOptionsPanelView.isHidden = true
        configPanelView.isHidden = false

        hideContactPopup()
        configPanelView.refresh()
    }

    // MARK: - AI恋爱回复专用
    func setHelpReplyInputText(_ text: String) {
        helpReplyPanelView.setInputText(text)
    }

    func getHelpReplyInputText() -> String {
        return helpReplyPanelView.getInputText()
    }

    func setHelpReplyContactName(_ name: String?) {
        helpReplyPanelView.setContactName(name)
    }

    func showCandidateLoading(_ message: String) {
        candidateBarView.showLoading(message)
    }

    func showCandidateMessage(_ message: String) {
        candidateBarView.showMessage(message)
    }

    func showAICandidates(_ replies: [String], contactName: String?) {
        candidateBarView.showAICandidates(replies, contactName: contactName)
    }

    func showHelpReplyReplies(_ replies: [String]) {
        helpReplyPanelView.setReplies(replies)
    }

    func showHelpReplyLoading(_ loading: Bool) {
        helpReplyPanelView.setLoading(loading)
    }

    func updateSelectedContact(_ contact: ChatContact?) {
        toolbarView.setSelectedContactName(contact?.name)
        helpReplyPanelView.setContactName(contact?.name)
    }

    // MARK: - 对象选择弹出列表
    private func setupContactPopup() {
        // 点击空白处关闭的遮罩
        contactPopupOverlay = UIButton(type: .system)
        contactPopupOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.15)
        contactPopupOverlay.addTarget(self, action: #selector(contactPopupOverlayTapped), for: .touchUpInside)
        contactPopupOverlay.translatesAutoresizingMaskIntoConstraints = false
        contactPopupOverlay.isHidden = true
        addSubview(contactPopupOverlay)

        // 弹出列表容器
        contactPopupContainer = UIView()
        contactPopupContainer.backgroundColor = .white
        contactPopupContainer.layer.cornerRadius = 12
        contactPopupContainer.layer.shadowColor = UIColor.black.cgColor
        contactPopupContainer.layer.shadowOpacity = 0.2
        contactPopupContainer.layer.shadowRadius = 8
        contactPopupContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        contactPopupContainer.translatesAutoresizingMaskIntoConstraints = false
        contactPopupContainer.isHidden = true
        addSubview(contactPopupContainer)

        contactPopupStack = UIStackView()
        contactPopupStack.axis = .vertical
        contactPopupStack.spacing = 0
        contactPopupStack.translatesAutoresizingMaskIntoConstraints = false
        contactPopupContainer.addSubview(contactPopupStack)

        NSLayoutConstraint.activate([
            contactPopupOverlay.topAnchor.constraint(equalTo: toolbarView.bottomAnchor),
            contactPopupOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            contactPopupOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            contactPopupOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            contactPopupContainer.topAnchor.constraint(equalTo: toolbarView.bottomAnchor, constant: 4),
            contactPopupContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            contactPopupContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            contactPopupStack.topAnchor.constraint(equalTo: contactPopupContainer.topAnchor, constant: 6),
            contactPopupStack.leadingAnchor.constraint(equalTo: contactPopupContainer.leadingAnchor, constant: 6),
            contactPopupStack.trailingAnchor.constraint(equalTo: contactPopupContainer.trailingAnchor, constant: -6),
            contactPopupStack.bottomAnchor.constraint(equalTo: contactPopupContainer.bottomAnchor, constant: -6)
        ])
    }

    func showContactPopup(_ contacts: [ChatContact]) {
        cachedContacts = contacts
        contactPopupStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if contacts.isEmpty {
            let label = UILabel()
            label.text = "暂无可用联系人"
            label.font = .systemFont(ofSize: 14)
            label.textColor = .gray
            label.textAlignment = .center
            label.heightAnchor.constraint(equalToConstant: 44).isActive = true
            contactPopupStack.addArrangedSubview(label)
        } else {
            let header = UILabel()
            header.text = "选择对象"
            header.font = .boldSystemFont(ofSize: 14)
            header.heightAnchor.constraint(equalToConstant: 32).isActive = true
            contactPopupStack.addArrangedSubview(header)

            for (index, contact) in contacts.prefix(8).enumerated() {
                let button = UIButton(type: .system)
                let score = Int(contact.profileScore)
                button.setTitle("\(contact.name) · 画像\(score)", for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 15)
                button.contentHorizontalAlignment = .left
                button.tag = index
                button.heightAnchor.constraint(equalToConstant: 40).isActive = true
                button.addTarget(self, action: #selector(contactOptionTapped(_:)), for: .touchUpInside)
                contactPopupStack.addArrangedSubview(button)
            }
        }

        contactPopupOverlay.isHidden = false
        contactPopupContainer.isHidden = false
        bringSubviewToFront(contactPopupContainer)
    }

    func hideContactPopup() {
        contactPopupOverlay.isHidden = true
        contactPopupContainer.isHidden = true
    }

    @objc private func contactOptionTapped(_ sender: UIButton) {
        let index = sender.tag
        guard index < cachedContacts.count else { return }
        delegate?.didSelectContact(cachedContacts[index])
    }

    @objc private func contactPopupOverlayTapped() {
        hideContactPopup()
    }

    // 超会说专用
    func updateCandidatesForSuperTalk(_ candidates: [String], pinyin: String) {
        superTalkPanelView.updateCandidates(candidates, pinyin: pinyin)
    }

    func updateSuperTalkInput(_ content: String, cursorPosition: Int) {
        superTalkPanelView.updateInputContent(content, cursorPosition: cursorPosition)
    }
}

// MARK: - ToolbarViewDelegate
extension KeyboardMainView: ToolbarViewDelegate {
    func toolbarDidTapLogo() {
        delegate?.didTapBackToKeyboard()
    }

    func toolbarDidTapHelpReply() {
        delegate?.didTapHelpReply()
    }

    func toolbarDidTapSuperTalk() {
        delegate?.didTapSuperTalk()
    }

    func toolbarDidTapMore() {
        delegate?.didTapMore()
    }

    func toolbarDidTapContact() {
        if !contactPopupContainer.isHidden {
            hideContactPopup()
        } else {
            delegate?.didTapContact()
        }
    }

    func toolbarDidTapPaste() {
        delegate?.didTapPaste()
    }

    func toolbarDidTapGenerate() {
        delegate?.didTapGenerate()
    }
}

// MARK: - CandidateBarViewDelegate
extension KeyboardMainView: CandidateBarViewDelegate {
    func candidateBarDidSelectCandidate(_ candidate: String, source: CandidateSource) {
        delegate?.didSelectCandidate(candidate, source: source)
    }
}

// MARK: - QwertyKeyboardViewDelegate
extension KeyboardMainView: QwertyKeyboardViewDelegate {
    func qwertyKeyboardDidTapKey(_ key: String) {
        delegate?.didTapKey(key)
    }

    func qwertyKeyboardDidTapDelete() {
        delegate?.didTapDelete()
    }

    func qwertyKeyboardDidTapSpace() {
        delegate?.didTapSpace()
    }

    func qwertyKeyboardDidTapReturn() {
        delegate?.didTapReturn()
    }

    func qwertyKeyboardDidTapShift() {
        delegate?.didTapShift()
    }

    func qwertyKeyboardDidDoubleTapShift() {
        delegate?.didDoubleTapShift()
    }

    func qwertyKeyboardDidTapLanguageSwitch() {
        delegate?.didTapLanguageSwitch()
    }

    func qwertyKeyboardDidTapKeyboardSwitch() {
        delegate?.didTapKeyboardSwitch()
    }

    func qwertyKeyboardDidTapSymbol() {
        delegate?.didTapSymbol()
    }
}

// MARK: - SymbolKeyboardViewDelegate
extension KeyboardMainView: SymbolKeyboardViewDelegate {
    func symbolKeyboardDidTapSymbol(_ symbol: String) {
        delegate?.didTapPunctuation(symbol)
    }

    func symbolKeyboardDidTapBack() {
        updateKeyboardType(.qwerty)
    }

    func symbolKeyboardDidTapDelete() {
        delegate?.didTapDelete()
    }

    func symbolKeyboardDidTapSpace() {
        delegate?.didTapSpace()
    }

    func symbolKeyboardDidTapReturn() {
        delegate?.didTapReturn()
    }
}

// MARK: - HelpReplyPanelViewDelegate
extension KeyboardMainView: HelpReplyPanelViewDelegate {
    func helpReplyPanelDidTapClose() {
        delegate?.didTapBackToKeyboard()
    }

    func helpReplyPanelDidTapPaste() -> String? {
        return delegate?.didRequestPaste()
    }

    func helpReplyPanelDidSelectReply(_ text: String) {
        delegate?.didRequestSendText(text)
    }

    func helpReplyPanelDidTapContact() {
        delegate?.didTapContact()
    }
}

// MARK: - SuperTalkPanelViewDelegate
extension KeyboardMainView: SuperTalkPanelViewDelegate {
    func superTalkPanelDidTapClose() {
        delegate?.didTapBackToKeyboard()
    }

    func superTalkPanelDidTapKey(_ key: String) {
        delegate?.didTapKeyForSuperTalk(key)
    }

    func superTalkPanelDidTapDelete() {
        delegate?.didTapDeleteForSuperTalk()
    }

    func superTalkPanelDidTapSpace() {
        delegate?.didTapSpaceForSuperTalk()
    }

    func superTalkPanelDidSelectCandidate(_ candidate: String) {
        delegate?.didSelectCandidateForSuperTalk(candidate)
    }

    func superTalkPanelDidTapCursorLeft() {
        delegate?.moveCursorLeft()
    }

    func superTalkPanelDidTapCursorRight() {
        delegate?.moveCursorRight()
    }

    func superTalkPanelDidSelectResult(_ text: String) {
        delegate?.didRequestSendText(text)
    }

    func superTalkPanelGetInputContent() -> String {
        return delegate?.getSuperTalkInputContent() ?? ""
    }
}

// MARK: - MoreOptionsPanelViewDelegate
extension KeyboardMainView: MoreOptionsPanelViewDelegate {
    func moreOptionsPanelDidTapClose() {
        delegate?.didTapBackToKeyboard()
    }

    func moreOptionsPanelDidSelectKeyboardType(_ type: KeyboardType) {
        currentKeyboardType = type
        StorageService.shared.keyboardType = type
        delegate?.didTapBackToKeyboard()
    }

    func moreOptionsPanelDidTapConfig() {
        delegate?.didTapConfig()
    }
}

// MARK: - ConfigPanelViewDelegate
extension KeyboardMainView: ConfigPanelViewDelegate {
    func configPanelDidTapClose() {
        delegate?.didTapBackToKeyboard()
    }

    func configPanelDidSave(gatewayURL: String, token: String, agentId: String) {
        // 保存成功：回到键盘，配置已写入 KeyboardConfigStore
        delegate?.didTapBackToKeyboard()
    }
}
