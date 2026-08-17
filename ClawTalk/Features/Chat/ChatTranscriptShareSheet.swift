import SwiftUI
import UIKit

/// 聊天记录分享（对齐官方 ChatTranscriptShareSheet）：
/// 把导出的对话文本/文件交给系统分享面板。
struct ChatTranscriptShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// 把消息文本导出为 UTF-8 文本文件（分享用）。
enum ChatTranscriptExporter {
    static func makeTextFile(messages: [(role: String, text: String)], title: String) -> URL? {
        var lines: [String] = ["# \(title)", ""]
        for message in messages {
            let role = message.role == "assistant" ? "AI" : (message.role == "user" ? "我" : message.role)
            lines.append("【\(role)】")
            lines.append(message.text)
            lines.append("")
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else { return nil }
        let directory = FileManager.default.temporaryDirectory
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(safeTitle).txt")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
