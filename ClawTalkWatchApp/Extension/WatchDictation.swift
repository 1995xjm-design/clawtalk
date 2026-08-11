import SwiftUI
import WatchKit

/// 系统听写（dictation）：watchOS 内置能力，不需要额外权限。
/// 通过当前可见的 WKInterfaceController 弹出系统听写界面。
enum WatchDictation {
    /// 弹出系统听写；完成回调返回文本，用户取消时返回 nil。
    static func present(completion: @escaping (String?) -> Void) {
        guard let controller = WKExtension.shared().visibleInterfaceController else {
            completion(nil)
            return
        }
        controller.presentTextInputController(
            withSuggestions: nil,
            allowedInputMode: .plain
        ) { results in
            let text: String?
            if let first = results?.first as? String {
                text = first
            } else if let attributed = results?.first as? NSAttributedString {
                text = attributed.string
            } else {
                text = nil
            }
            completion(text)
        }
    }
}

/// 语音输入按钮：点击后弹系统听写，回调返回听写文本（空文本不回调）。
struct VoiceInputButton: View {
    var onText: (String) -> Void

    @State private var isPresenting = false

    var body: some View {
        Button {
            isPresenting = true
            WatchDictation.present { text in
                isPresenting = false
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmed.isEmpty else { return }
                onText(trimmed)
            }
        } label: {
            Label("语音", systemImage: "mic.fill")
        }
        .disabled(isPresenting)
    }
}