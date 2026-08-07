import UIKit

// MARK: - 候选数据源标记
enum CandidateSource {
    case pinyin
    case aiReply
}

// MARK: - CandidateBarViewDelegate协议
protocol CandidateBarViewDelegate: AnyObject {
    func candidateBarDidSelectCandidate(_ candidate: String, source: CandidateSource)
}

/// 候选词栏视图 - 拼音候选词与AI回复候选共用，通过数据源标记区分
class CandidateBarView: UIView {

    // MARK: - Delegate
    weak var delegate: CandidateBarViewDelegate?

    // MARK: - UI组件
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var currentSource: CandidateSource = .pinyin

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

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.spacing = 12
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
            stackView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])
    }

    private func clearStack() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    // MARK: - 公共方法
    /// 拼音候选（原有功能）
    func updateCandidates(_ candidates: [String], pinyin: String = "") {
        currentSource = .pinyin
        clearStack()

        // 如果有拼音，先显示拼音
        if !pinyin.isEmpty {
            let pinyinLabel = UILabel()
            pinyinLabel.text = pinyin
            pinyinLabel.font = .systemFont(ofSize: 14)
            pinyinLabel.textColor = .gray
            stackView.addArrangedSubview(pinyinLabel)
        }

        for candidate in candidates {
            let button = UIButton(type: .system)
            button.setTitle(candidate, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 18)
            button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
    }

    /// 纯提示消息（空态/错误，无转圈）
    func showMessage(_ message: String) {
        currentSource = .aiReply
        clearStack()

        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 14)
        label.textColor = .gray
        stackView.addArrangedSubview(label)
    }

    /// 生成中loading状态（如「正在分析对方画像…」）
    func showLoading(_ message: String) {
        currentSource = .aiReply
        clearStack()

        let label = UILabel()
        label.text = message
        label.font = .systemFont(ofSize: 14)
        label.textColor = .gray
        stackView.addArrangedSubview(label)

        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.startAnimating()
        stackView.addArrangedSubview(indicator)
    }

    /// AI回复候选（带数据源标记）
    func showAICandidates(_ replies: [String], contactName: String?) {
        currentSource = .aiReply
        clearStack()

        // 数据源标记徽标
        let badge = UILabel()
        badge.text = "AI"
        badge.font = .boldSystemFont(ofSize: 12)
        badge.textColor = .white
        badge.backgroundColor = .systemPink
        badge.textAlignment = .center
        badge.layer.cornerRadius = 4
        badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 26).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stackView.addArrangedSubview(badge)

        if let contactName = contactName, !contactName.isEmpty {
            let contactLabel = UILabel()
            contactLabel.text = contactName
            contactLabel.font = .systemFont(ofSize: 12)
            contactLabel.textColor = .systemPink
            stackView.addArrangedSubview(contactLabel)
        }

        for reply in replies {
            let button = UIButton(type: .system)
            button.setTitle(reply, for: .normal)
            button.tintColor = .systemPink
            button.titleLabel?.font = .systemFont(ofSize: 15)
            button.addTarget(self, action: #selector(candidateTapped(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
        }
    }

    // MARK: - 事件处理
    @objc private func candidateTapped(_ sender: UIButton) {
        guard let text = sender.title(for: .normal) else { return }
        delegate?.candidateBarDidSelectCandidate(text, source: currentSource)
    }
}