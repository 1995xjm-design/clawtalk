import SwiftUI

/// ClawTalk watchOS 入口（@main 编译进 ClawTalkWatchExtension target；
/// watch app 容器 target 只含 Info.plist 与资源，这是 watchOS 的标准结构）。
@main
struct ClawTalkWatchApp: App {
    @StateObject private var session = WatchSessionManager.shared

    var body: some Scene {
        WindowGroup {
            MessageListView()
                .environmentObject(session)
                .alert(item: $session.pendingNotify) { item in
                    Alert(
                        title: Text(item.title),
                        message: Text(item.body),
                        dismissButton: .default(Text("确定"))
                    )
                }
        }
    }
}