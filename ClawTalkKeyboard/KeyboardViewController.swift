import UIKit

// MARK: - 键盘主控制器
class KeyboardViewController: UIInputViewController {

    // MARK: - Properties
    private var keyboardView: KeyboardMainView!
    private var currentKeyboardType: KeyboardType = .qwerty
    private var inputMode: InputMode = .chinese
    private var isShiftOn: Bool = false
    private var isCapsLockOn: Bool = false

    // 拼音引擎
    private var pinyinEngine: PinyinEngine!
    private var pinyinBuffer: String = ""
    private var candidates: [String] = []

    // 当前面板模式
    private var currentPanelMode: PanelMode = .keyboard

    enum PanelMode {
        case keyboard
        case helpReplyInput
        case helpReplyResult
        case superTalkInput
        case superTalkResult
        case moreOptions
    }

    // 超会说输入内容
    private var superTalkInputContent: String = ""
    private var superTalkCursorPosition: Int = 0

    // AI恋爱回复
    private var selectedContact: ChatContact?
    private var isGeneratingAI: Bool = false

    // MARK: - Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
        setupPinyinEngine()
        loadUserPreferences()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateKeyboardHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 重新加载用户设置
        loadUserPreferences()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 键盘收起/切换时停止朗读与录音，避免后台残留
        SpeechSynthesizerService.shared.stop()
        VoiceInputService.shared.cancel()
    }

    // MARK: - Setup
    private func setupKeyboard() {
        keyboardView = KeyboardMainView(frame: view.bounds)
        keyboardView.delegate = self
        keyboardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardView)

        NSLayoutConstraint.activate([
            keyboardView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardView.topAnchor.constraint(equalTo: view.topAnchor),
            keyboardView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func setupPinyinEngine() {
        pinyinEngine = PinyinEngine()
    }

    private func loadUserPreferences() {
        let storage = StorageService.shared
        currentKeyboardType = storage.keyboardType
        keyboardView?.updateKeyboardType(currentKeyboardType)
    }

    private func updateKeyboardHeight() {
        let baseHeight: CGFloat = 291
        let additionalHeight: CGFloat = needsInputModeSwitchKey ? 0 : -20

        var height = baseHeight + additionalHeight

        // 根据面板模式调整高度
        switch currentPanelMode {
        case .helpReplyInput, .helpReplyResult, .superTalkInput, .superTalkResult:
            height = 350
        case .moreOptions:
            height = 320
        default:
            break
        }

        view.frame.size.height = height
    }

    // MARK: - Text Input
    func insertText(_ text: String) {
        textDocumentProxy.insertText(text)
        provideFeedback()
    }

    func deleteBackward() {
        textDocumentProxy.deleteBackward()
        provideFeedback()
    }

    // MARK: - Feedback
    private func provideFeedback() {
        if StorageService.shared.hapticEnabled {
            HapticManager.shared.keyPress()
        }
    }

}

// MARK: - KeyboardMainViewDelegate
extension KeyboardViewController: KeyboardMainViewDelegate {

    func didTapKey(_ key: String) {
        if inputMode == .chinese && key.count == 1 && key.first!.isLetter {
            // 中文模式，累积拼音
            pinyinBuffer.append(key.lowercased())
            updateCandidates()
        } else {
            // 英文模式或非字母键
            commitPinyinBuffer()
            let outputKey = isShiftOn || isCapsLockOn ? key.uppercased() : key.lowercased()
            insertText(outputKey)

            if isShiftOn && !isCapsLockOn {
                isShiftOn = false
                keyboardView?.updateShiftState(isShiftOn)
            }
        }
    }

    func didTapDelete() {
        if !pinyinBuffer.isEmpty {
            pinyinBuffer.removeLast()
            updateCandidates()
        } else {
            deleteBackward()
        }
    }

    func didTapSpace() {
        if !pinyinBuffer.isEmpty && !candidates.isEmpty {
            // 选择第一个候选词
            selectCandidate(candidates[0])
        } else {
            insertText(" ")
        }
    }

    func didTapReturn() {
        commitPinyinBuffer()
        insertText("\n")
    }

    func didTapShift() {
        isShiftOn.toggle()
        keyboardView?.updateShiftState(isShiftOn)
    }

    func didDoubleTapShift() {
        isCapsLockOn.toggle()
        isShiftOn = isCapsLockOn
        keyboardView?.updateCapsLockState(isCapsLockOn)
    }

    func didTapLanguageSwitch() {
        inputMode = inputMode == .chinese ? .english : .chinese
        commitPinyinBuffer()
        keyboardView?.updateInputMode(inputMode)
    }

    func didTapKeyboardSwitch() {
        // 切换到下一个键盘
        advanceToNextInputMode()
    }

    func didTapSymbol() {
        commitPinyinBuffer()
        currentKeyboardType = currentKeyboardType == .symbol ? .qwerty : .symbol
        keyboardView?.updateKeyboardType(currentKeyboardType)
    }

    func didTapNumber() {
        commitPinyinBuffer()
        currentKeyboardType = currentKeyboardType == .number ? .qwerty : .number
        keyboardView?.updateKeyboardType(currentKeyboardType)
    }

    func didSelectCandidate(_ candidate: String, source: CandidateSource) {
        if source == .aiReply {
            // AI回复候选：直接上屏
            insertText(candidate)
            keyboardView?.updateCandidates([], pinyin: "")
            didTapBackToKeyboard()
        } else {
            selectCandidate(candidate)
        }
    }

    func didTapHelpReply() {
        currentPanelMode = .helpReplyInput
        isGeneratingAI = false
        keyboardView?.showHelpReplyPanel()
        keyboardView?.updateSelectedContact(selectedContact)
        keyboardView?.updateCandidates([], pinyin: "")
        updateKeyboardHeight()
    }

    func didTapSuperTalk() {
        currentPanelMode = .superTalkInput
        superTalkInputContent = ""
        superTalkCursorPosition = 0
        keyboardView?.showSuperTalkPanel()
        updateKeyboardHeight()
    }

    func didTapMore() {
        currentPanelMode = .moreOptions
        keyboardView?.showMoreOptionsPanel()
        updateKeyboardHeight()
    }

    func didTapConfig() {
        currentPanelMode = .moreOptions
        keyboardView?.showConfigPanel()
        updateKeyboardHeight()
    }

    // MARK: - AI恋爱回复
    func didTapContact() {
        ensureHelpReplyPanel()
        fetchAndShowContacts()
    }

    func didTapPaste() {
        ensureHelpReplyPanel()
        if let text = didRequestPaste(), !text.isEmpty {
            keyboardView?.setHelpReplyInputText(text)
        } else {
            keyboardView?.showCandidateMessage("剪贴板为空或未开启完全访问")
        }
    }

    func didTapGenerate() {
        ensureHelpReplyPanel()
        generateAIReplies()
    }

    // MARK: - 语音输入（按住说话）
    func didTouchDownVoice() {
        VoiceInputService.shared.delegate = self
        VoiceInputService.shared.start()
    }

    func didTouchUpVoice() {
        VoiceInputService.shared.finish()
    }

    func didVoiceCancel() {
        VoiceInputService.shared.cancel()
    }

    func didSelectContact(_ contact: ChatContact) {
        selectedContact = contact
        keyboardView?.updateSelectedContact(contact)
        keyboardView?.hideContactPopup()
    }

    func didTapBackToKeyboard() {
        // 回到键盘时停止朗读（面板关闭/回复已上屏）
        SpeechSynthesizerService.shared.stop()

        currentPanelMode = .keyboard
        keyboardView?.showKeyboard()
        keyboardView?.updateCandidates([], pinyin: "")
        updateKeyboardHeight()
    }

    func didTapPunctuation(_ punctuation: String) {
        commitPinyinBuffer()
        insertText(punctuation)
    }

    func didRequestPaste() -> String? {
        guard hasFullAccess else { return nil }
        return UIPasteboard.general.string
    }

    func didRequestSendText(_ text: String) {
        insertText(text)
        didTapBackToKeyboard()
    }

    // MARK: - 超会说键盘输入处理
    func didTapKeyForSuperTalk(_ key: String) {
        if inputMode == .chinese && key.count == 1 && key.first!.isLetter {
            pinyinBuffer.append(key.lowercased())
            updateCandidatesForSuperTalk()
        } else {
            commitPinyinBufferForSuperTalk()
            let outputKey = isShiftOn || isCapsLockOn ? key.uppercased() : key.lowercased()
            insertTextAtCursor(outputKey)

            if isShiftOn && !isCapsLockOn {
                isShiftOn = false
                keyboardView?.updateShiftState(isShiftOn)
            }
        }
    }

    func didTapDeleteForSuperTalk() {
        if !pinyinBuffer.isEmpty {
            pinyinBuffer.removeLast()
            updateCandidatesForSuperTalk()
        } else {
            deleteCharBeforeCursor()
        }
    }

    func didTapSpaceForSuperTalk() {
        if !pinyinBuffer.isEmpty && !candidates.isEmpty {
            selectCandidateForSuperTalk(candidates[0])
        } else {
            insertTextAtCursor(" ")
        }
    }

    func didSelectCandidateForSuperTalk(_ candidate: String) {
        selectCandidateForSuperTalk(candidate)
    }
}

// MARK: - Pinyin Handling
extension KeyboardViewController {

    private func updateCandidates() {
        if pinyinBuffer.isEmpty {
            candidates = []
        } else {
            candidates = pinyinEngine.getCandidates(for: pinyinBuffer)
        }
        keyboardView?.updateCandidates(candidates, pinyin: pinyinBuffer)
    }

    private func selectCandidate(_ candidate: String) {
        insertText(candidate)
        pinyinBuffer = ""
        candidates = []
        keyboardView?.updateCandidates([], pinyin: "")
    }

    private func commitPinyinBuffer() {
        if !pinyinBuffer.isEmpty {
            // 如果有候选词，选择第一个；否则直接输出拼音
            if !candidates.isEmpty {
                insertText(candidates[0])
            } else {
                insertText(pinyinBuffer)
            }
            pinyinBuffer = ""
            candidates = []
            keyboardView?.updateCandidates([], pinyin: "")
        }
    }

    // 超会说专用
    private func updateCandidatesForSuperTalk() {
        if pinyinBuffer.isEmpty {
            candidates = []
        } else {
            candidates = pinyinEngine.getCandidates(for: pinyinBuffer)
        }
        keyboardView?.updateCandidatesForSuperTalk(candidates, pinyin: pinyinBuffer)
    }

    private func selectCandidateForSuperTalk(_ candidate: String) {
        insertTextAtCursor(candidate)
        pinyinBuffer = ""
        candidates = []
        keyboardView?.updateCandidatesForSuperTalk([], pinyin: "")
    }

    private func commitPinyinBufferForSuperTalk() {
        if !pinyinBuffer.isEmpty {
            if !candidates.isEmpty {
                insertTextAtCursor(candidates[0])
            } else {
                insertTextAtCursor(pinyinBuffer)
            }
            pinyinBuffer = ""
            candidates = []
            keyboardView?.updateCandidatesForSuperTalk([], pinyin: "")
        }
    }

    // 光标位置操作
    private func insertTextAtCursor(_ text: String) {
        let index = superTalkInputContent.index(superTalkInputContent.startIndex, offsetBy: superTalkCursorPosition)
        superTalkInputContent.insert(contentsOf: text, at: index)
        superTalkCursorPosition += text.count
        keyboardView?.updateSuperTalkInput(superTalkInputContent, cursorPosition: superTalkCursorPosition)
    }

    private func deleteCharBeforeCursor() {
        guard superTalkCursorPosition > 0 else { return }
        let index = superTalkInputContent.index(superTalkInputContent.startIndex, offsetBy: superTalkCursorPosition - 1)
        superTalkInputContent.remove(at: index)
        superTalkCursorPosition -= 1
        keyboardView?.updateSuperTalkInput(superTalkInputContent, cursorPosition: superTalkCursorPosition)
    }

    func moveCursorLeft() {
        if superTalkCursorPosition > 0 {
            superTalkCursorPosition -= 1
            keyboardView?.updateSuperTalkInput(superTalkInputContent, cursorPosition: superTalkCursorPosition)
        }
    }

    func moveCursorRight() {
        if superTalkCursorPosition < superTalkInputContent.count {
            superTalkCursorPosition += 1
            keyboardView?.updateSuperTalkInput(superTalkInputContent, cursorPosition: superTalkCursorPosition)
        }
    }

    func getSuperTalkInputContent() -> String {
        return superTalkInputContent
    }
}

// MARK: - AI恋爱回复
extension KeyboardViewController {

    private func ensureHelpReplyPanel() {
        if currentPanelMode != .helpReplyInput {
            didTapHelpReply()
        }
    }

    private func fetchAndShowContacts() {
        Task { @MainActor in
            let contacts = (try? await ContactListService.fetchContacts()) ?? []
            keyboardView?.showContactPopup(contacts)
        }
    }

    private func generateAIReplies() {
        guard !isGeneratingAI else { return }

        let inputText = (keyboardView?.getHelpReplyInputText() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputText.isEmpty else {
            keyboardView?.showCandidateMessage("请先粘贴或输入对方的话")
            return
        }

        isGeneratingAI = true
        let message = selectedContact != nil ? "正在分析对方画像…" : "正在生成回复…"
        keyboardView?.showCandidateLoading(message)
        keyboardView?.showHelpReplyLoading(true)

        let contact = selectedContact
        Task { @MainActor in
            let replies = await ReplySuggestService.suggestReplies(contact: contact, text: inputText, style: nil, count: 5)
            isGeneratingAI = false
            keyboardView?.showHelpReplyLoading(false)

            if replies.isEmpty {
                keyboardView?.showCandidateMessage("暂无回复，请换个说法试试")
            } else {
                keyboardView?.showAICandidates(replies, contactName: contact?.name)
                keyboardView?.showHelpReplyReplies(replies)
            }
        }
    }
}

// MARK: - VoiceInputServiceDelegate
extension KeyboardViewController: VoiceInputServiceDelegate {

    func voiceInputDidChangeState(_ state: VoiceInputService.State) {
        switch state {
        case .idle:
            keyboardView?.setVoiceRecording(false)
        case .recording:
            keyboardView?.setVoiceRecording(true)
            keyboardView?.showCandidateMessage("正在录音，松开发送")
        case .transcribing:
            keyboardView?.setVoiceRecording(false)
            keyboardView?.showCandidateLoading("正在识别…")
        }
    }

    func voiceInputDidProduceText(_ text: String) {
        keyboardView?.setVoiceRecording(false)
        insertText(text)
        // 清掉候选栏的识别提示，恢复正常键盘状态
        keyboardView?.updateCandidates([], pinyin: "")
    }

    func voiceInputDidFail(_ message: String) {
        keyboardView?.setVoiceRecording(false)
        keyboardView?.showCandidateMessage(message)
    }
}

// MARK: - Haptic Manager
class HapticManager {

    static let shared = HapticManager()

    private let impactGenerator = UIImpactFeedbackGenerator(style: .light)

    private init() {
        impactGenerator.prepare()
    }

    func prepare() {
        impactGenerator.prepare()
    }

    func keyPress() {
        impactGenerator.impactOccurred()
    }
}


