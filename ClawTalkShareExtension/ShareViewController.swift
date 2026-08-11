import SwiftUI
import UIKit

/// 分享扩展入口：加载分享内容 → 频道选择 → 写入 App Group 待发消息。
final class ShareViewController: UIViewController {
    private let loader = SharePayloadLoader()
    private var loadingController: UIViewController?
    private var hasCompleted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        showLoading()
        loader.load(from: extensionContext) { [weak self] payload in
            guard let self else { return }
            self.hideLoading()
            guard payload.hasContent else {
                self.complete(cancelled: true)
                return
            }
            self.presentPicker(payload: payload)
        }
    }

    private func showLoading() {
        let hosting = UIHostingController(rootView: ShareLoadingView())
        embed(hosting)
        loadingController = hosting
    }

    private func hideLoading() {
        if let loadingController {
            loadingController.willMove(toParent: nil)
            loadingController.view.removeFromSuperview()
            loadingController.removeFromParent()
        }
        loadingController = nil
    }

    private func presentPicker(payload: SharePayload) {
        let picker = ShareChannelPickerView(payload: payload) { [weak self] action in
            guard let self else { return }
            switch action {
            case .cancelled:
                self.complete(cancelled: true)
            case .saved:
                self.complete(cancelled: false)
            case .failed(let message):
                self.showFailure(message)
            }
        }
        let hosting = UIHostingController(rootView: picker)
        let navigation = UINavigationController(rootViewController: hosting)
        embed(navigation)
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(child.view)
        child.didMove(toParent: self)
    }

    private func showFailure(_ message: String) {
        let alert = UIAlertController(title: "发送失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            self?.complete(cancelled: true)
        })
        present(alert, animated: true)
    }

    private func complete(cancelled: Bool) {
        guard !hasCompleted else { return }
        hasCompleted = true
        if cancelled {
            extensionContext?.cancelRequest(
                withError: NSError(
                    domain: "ClawTalkShare",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "用户取消分享"]
                )
            )
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

private struct ShareLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在读取分享内容…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}