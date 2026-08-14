import XCTest
@testable import ClawTalk

@MainActor
final class ChatViewModelTests: XCTestCase {

    /// 构造一条非空消息（ConversationStore.save 会过滤空内容）。
    private func makeMessage(_ index: Int) -> Message {
        Message(role: .user, content: "msg-\(index)")
    }

    /// 先把 N 条消息写入 ConversationStore，再用同一 channel 构建 ChatViewModel，
    /// 复刻 init 中「只显示最近 pageSize 条」的窗口初始化。
    private func makeViewModel(messageCount: Int) -> ChatViewModel {
        let channel = Channel(name: "Test", agentId: "main")
        let messages = (0..<messageCount).map(makeMessage)
        ConversationStore.shared.save(messages, channelId: channel.id)
        let vm = ChatViewModel(settings: SettingsStore(), channel: channel)
        // 构建后立即清掉落盘数据，避免污染其他测试
        ConversationStore.shared.clear(channelId: channel.id)
        return vm
    }

    // MARK: - displayedMessages 窗口

    func testEmptyConversationHasEmptyWindow() {
        let vm = makeViewModel(messageCount: 0)
        XCTAssertTrue(vm.displayedMessages.isEmpty)
        XCTAssertFalse(vm.canLoadEarlier)
        XCTAssertEqual(vm.oldestShownIndex, 0)
    }

    func testInitialWindowShowsLastPage() {
        let vm = makeViewModel(messageCount: 120)
        // init: oldestShownIndex = max(0, 120 - 50) = 70
        XCTAssertEqual(vm.oldestShownIndex, 70)
        XCTAssertTrue(vm.canLoadEarlier)
        XCTAssertEqual(vm.displayedMessages.count, 50)
        XCTAssertEqual(vm.displayedMessages.first?.id, Optional(vm.messages[70].id))
        XCTAssertEqual(vm.displayedMessages.last?.id, Optional(vm.messages[119].id))
    }

    func testFewerThanPageSizeShowsAll() {
        let vm = makeViewModel(messageCount: 30)
        XCTAssertEqual(vm.oldestShownIndex, 0)
        XCTAssertFalse(vm.canLoadEarlier)
        XCTAssertEqual(vm.displayedMessages.count, 30)
    }

    func testWindowClampsWhenMessagesShrink() {
        let vm = makeViewModel(messageCount: 120)
        // 消息数组被压缩时窗口指针超出内容长度，displayedMessages 必须夹紧到最后一个元素
        vm.messages = Array(vm.messages.suffix(10))
        XCTAssertEqual(vm.displayedMessages.count, 1)
        XCTAssertEqual(vm.displayedMessages.first?.id, vm.messages.last?.id)
    }

    // MARK: - loadEarlierMessages 夹紧

    func testLoadEarlierExpandsWindow() async throws {
        let vm = makeViewModel(messageCount: 120)
        vm.loadEarlierMessages()
        XCTAssertTrue(vm.isLoadingEarlier)
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.oldestShownIndex, 20)
        XCTAssertEqual(vm.displayedMessages.count, 100)
        XCTAssertFalse(vm.isLoadingEarlier)
        XCTAssertTrue(vm.canLoadEarlier)
    }

    func testLoadEarlierClampsAtZero() async throws {
        let vm = makeViewModel(messageCount: 60)
        XCTAssertEqual(vm.oldestShownIndex, 10)
        vm.loadEarlierMessages()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.oldestShownIndex, 0)
        XCTAssertEqual(vm.displayedMessages.count, 60)
        XCTAssertFalse(vm.canLoadEarlier)
    }

    func testLoadEarlierNoopWhenAlreadyAtTop() async throws {
        let vm = makeViewModel(messageCount: 60)
        vm.loadEarlierMessages()
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.oldestShownIndex, 0)
        // 已到顶部再触发：guard canLoadEarlier 拦截，窗口不展开
        vm.loadEarlierMessages()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.oldestShownIndex, 0)
        XCTAssertFalse(vm.isLoadingEarlier)
        XCTAssertEqual(vm.displayedMessages.count, 60)
    }

    // MARK: - revealMessage 搜索跳转

    func testRevealMessageExpandsWindowToTarget() {
        let vm = makeViewModel(messageCount: 120)
        let target = vm.messages[10]
        XCTAssertLessThan(10, vm.oldestShownIndex)
        vm.revealMessage(id: target.id)
        XCTAssertEqual(vm.oldestShownIndex, 10)
        XCTAssertEqual(vm.displayedMessages.first?.id, Optional(target.id))
    }

    func testRevealMessageInsideWindowIsNoop() {
        let vm = makeViewModel(messageCount: 120)
        let inWindow = vm.messages[100]
        vm.revealMessage(id: inWindow.id)
        XCTAssertEqual(vm.oldestShownIndex, 70)
    }
}