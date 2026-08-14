//
//  PinyinCandidateRowView.swift
//
//  中文拼音九宫格主页面「拼音行」：只放 Rime 拼音候选，横向滚动，禁止放业务按钮。
//

import Combine
import UIKit

/// 拼音候选行（44pt）：数据源 = Rime 拼音候选，点击将输入编码替换为所选拼音
final class PinyinCandidateRowView: UIView {
  private let rimeContext: RimeContext
  private var subscriptions = Set<AnyCancellable>()

  private lazy var scrollView: UIScrollView = {
    let view = UIScrollView(frame: .zero)
    view.showsHorizontalScrollIndicator = false
    view.alwaysBounceHorizontal = true
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private lazy var stackView: UIStackView = {
    let view = UIStackView(frame: .zero)
    view.axis = .horizontal
    view.spacing = 6
    view.alignment = .center
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  init(rimeContext: RimeContext) {
    self.rimeContext = rimeContext
    super.init(frame: .zero)
    setupViews()
    bind()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    backgroundColor = .clear
    addSubview(scrollView)
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 10),
      stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -10),
      stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
    ])
  }

  private func bind() {
    rimeContext.userInputKeyPublished
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.reload()
      }
      .store(in: &subscriptions)
  }

  /// 拼音候选更新：清空并重建
  func reload() {
    stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

    let pinyins = rimeContext.getPinyinCandidates()
    for pinyin in pinyins {
      let button = UIButton(type: .system)
      button.setTitle(pinyin, for: .normal)
      button.setTitleColor(ClawIOSNativePalette.candidateText, for: .normal)
      button.titleLabel?.font = .systemFont(ofSize: 15)
      button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
      button.addTarget(self, action: #selector(pinyinTapped(_:)), for: .touchUpInside)
      stackView.addArrangedSubview(button)
    }
  }

  @objc private func pinyinTapped(_ sender: UIButton) {
    guard let pinyin = sender.title(for: .normal), !pinyin.isEmpty else { return }
    rimeContext.selectPinyinCandidate(pinyin)
  }
}
