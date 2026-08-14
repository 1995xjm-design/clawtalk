import XCTest
@testable import ClawTalk

@MainActor
final class GlobalVoiceInputTests: XCTestCase {

    private func makeViewModel() -> GlobalVoiceInputViewModel {
        GlobalVoiceInputViewModel(settingsStore: SettingsStore())
    }

    // MARK: - 模式 / 状态枚举

    func testModeCases() {
        XCTAssertEqual(GlobalVoiceInputMode.allCases, [.short, .long])
        XCTAssertEqual(GlobalVoiceInputMode.short.id, "short")
        XCTAssertEqual(GlobalVoiceInputMode.long.id, "long")
        for mode in GlobalVoiceInputMode.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.hint.isEmpty)
        }
    }

    func testStateEquality() {
        XCTAssertEqual(GlobalVoiceInputState.idle, GlobalVoiceInputState.idle)
        XCTAssertNotEqual(GlobalVoiceInputState.idle, GlobalVoiceInputState.recording)
        XCTAssertNotEqual(GlobalVoiceInputState.recording, GlobalVoiceInputState.transcribing)
    }

    // MARK: - 状态机（idle -> recording -> idle）

    func testInitialState() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.mode, .short)
    }

    func testBeginRecordingEntersRecordingState() {
        let vm = makeViewModel()
        vm.beginRecordingForTesting()
        XCTAssertEqual(vm.state, .recording)
    }

    func testStopShortRecordingDiscardsAccidentalTap() {
        let vm = makeViewModel()
        vm.beginRecordingForTesting()
        // 立即松手：时长 < 0.5s 视为误触，回到 idle，不进入转写
        vm.stopShortRecording()
        XCTAssertEqual(vm.state, .idle)
    }

    func testDiscardAbortsRecording() {
        let vm = makeViewModel()
        vm.beginRecordingForTesting()
        vm.discard()
        XCTAssertEqual(vm.state, .idle)
    }

    // MARK: - 守卫（非录音态调用均为 no-op）

    func testSwitchToLongModeFromIdleIsNoop() {
        let vm = makeViewModel()
        vm.switchToLongMode()
        XCTAssertEqual(vm.state, .idle)
        XCTAssertEqual(vm.mode, .short)
    }

    func testStopShortRecordingFromIdleIsNoop() {
        let vm = makeViewModel()
        vm.stopShortRecording()
        XCTAssertEqual(vm.state, .idle)
    }

    func testStopLongRecordingFromIdleIsNoop() {
        let vm = makeViewModel()
        vm.stopLongRecording()
        XCTAssertEqual(vm.state, .idle)
    }

    func testDiscardFromIdleKeepsIdle() {
        let vm = makeViewModel()
        vm.discard()
        XCTAssertEqual(vm.state, .idle)
        XCTAssertNil(vm.errorMessage)
    }
}