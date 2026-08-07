import UIKit

// MARK: - ConfigPanelViewDelegate协议
protocol ConfigPanelViewDelegate: AnyObject {
    func configPanelDidTapClose()
    func configPanelDidSave(gatewayURL: String, token: String, agentId: String)
}

/// 网关配置面板 - 键盘独立配置（绕过 App Group）
/// 免费 Apple ID 签名不支持 App Groups，键盘需要手填网关信息。
/// 三个字段：网关地址 / 网关令牌 / 智能体 ID
class ConfigPanelView: UIView {

    // MARK: - Delegate
    weak var delegate: ConfigPanelViewDelegate?

    // MARK: - UI组件
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let urlField = UITextField()
    private let tokenField = UITextField()
    private let agentField = UITextField()
    private let saveButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let statusLabel = UILabel()

    // MARK: - 初始化
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        loadCurrentConfig()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
        loadCurrentConfig()
    }

    // MARK: - UI设置
    private func setupUI() {
        backgroundColor = .white

        // 关闭按钮
        closeButton.setTitle("×", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 24)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        // 标题
        titleLabel.text = "网关设置"
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 提示
        hintLabel.text = "键盘独立连接 OpenClaw 网关（无需主 App 设置）"
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .gray
        hintLabel.numberOfLines = 0
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        // 网关地址
        let urlLabel = makeFieldLabel("网关地址")
        urlField.placeholder = "https://vm-0-17-ubuntu.tail6c7e5b.ts.net"
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.borderStyle = .roundedRect
        urlField.font = .systemFont(ofSize: 13)
        urlField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(urlLabel)
        addSubview(urlField)

        // 网关令牌
        let tokenLabel = makeFieldLabel("网关令牌")
        tokenField.placeholder = "粘贴你的 OpenClaw 访问令牌"
        tokenField.isSecureTextEntry = false
        tokenField.autocapitalizationType = .none
        tokenField.autocorrectionType = .no
        tokenField.borderStyle = .roundedRect
        tokenField.font = .systemFont(ofSize: 13)
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tokenLabel)
        addSubview(tokenField)

        // 智能体 ID
        let agentLabel = makeFieldLabel("智能体 ID")
        agentField.placeholder = "main"
        agentField.autocapitalizationType = .none
        agentField.autocorrectionType = .no
        agentField.borderStyle = .roundedRect
        agentField.font = .systemFont(ofSize: 13)
        agentField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(agentLabel)
        addSubview(agentField)

        // 状态提示（保存成功/失败）
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .systemGreen
        statusLabel.textAlignment = .center
        statusLabel.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        // 保存按钮
        saveButton.setTitle("保存配置", for: .normal)
        saveButton.titleLabel?.font = .boldSystemFont(ofSize: 15)
        saveButton.setTitleColor(.white, for: .normal)
        saveButton.backgroundColor = UIColor.primaryPink
        saveButton.layer.cornerRadius = 10
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(saveButton)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 40),
            closeButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            hintLabel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            urlLabel.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 14),
            urlLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            urlLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            urlField.topAnchor.constraint(equalTo: urlLabel.bottomAnchor, constant: 4),
            urlField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            urlField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            urlField.heightAnchor.constraint(equalToConstant: 36),

            tokenLabel.topAnchor.constraint(equalTo: urlField.bottomAnchor, constant: 10),
            tokenLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            tokenLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            tokenField.topAnchor.constraint(equalTo: tokenLabel.bottomAnchor, constant: 4),
            tokenField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            tokenField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            tokenField.heightAnchor.constraint(equalToConstant: 36),

            agentLabel.topAnchor.constraint(equalTo: tokenField.bottomAnchor, constant: 10),
            agentLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            agentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            agentField.topAnchor.constraint(equalTo: agentLabel.bottomAnchor, constant: 4),
            agentField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            agentField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            agentField.heightAnchor.constraint(equalToConstant: 36),

            statusLabel.topAnchor.constraint(equalTo: agentField.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            saveButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            saveButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            saveButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func makeFieldLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor.textPrimary
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - 数据
    private func loadCurrentConfig() {
        let store = KeyboardConfigStore.shared
        urlField.text = store.gatewayURL
        tokenField.text = store.token
        agentField.text = store.agentId
    }

    /// 面板再次打开时刷新显示当前保存的配置
    func refresh() {
        loadCurrentConfig()
        statusLabel.isHidden = true
    }

    // MARK: - 事件
    @objc private func closeTapped() {
        delegate?.configPanelDidTapClose()
    }

    @objc private func saveTapped() {
        let url = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = tokenField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agent = agentField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !url.isEmpty, !token.isEmpty, !agent.isEmpty else {
            statusLabel.text = "三项都需要填写"
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
            return
        }

        // 保存到键盘本地配置
        KeyboardConfigStore.shared.save(gatewayURL: url, token: token, agentId: agent)

        statusLabel.text = "已保存 ✓"
        statusLabel.textColor = .systemGreen
        statusLabel.isHidden = false

        delegate?.configPanelDidSave(gatewayURL: url, token: token, agentId: agent)
    }
}
