# FIX-F2-VOICE-STATEMACHINE-20260815 线F2 语音输入 4 套逻辑统一（共用状态机）

## 根因/背景
- 主 App 存在 4 套语音输入逻辑：① 键盘波形面板按住说话/右滑通话（KeyboardPackages，与主 App 分属不同进程）；② 频道输入栏微信弧形选择（WeChatInputBar）；③ GlobalVoiceInputEmbedded 内嵌录音区（各功能页底部）；④ 各功能页旧录音按钮（日记/悬浮球/纪念日/自动化等，各自持有 AudioCaptureManager + 重复的 STT 工厂 + 电平轮询 + 唤醒会话管理）。
- 每套逻辑各自实现「录音开始/结束/取消/上滑/转写」+ STT 工厂 + 会话生命周期，规则大体相同但代码分散在 10+ 文件，行为漂移、难以维护。
- 目标：收成一套共用状态机，主 App 侧全部入口复用，行为/动画零变化；键盘包保持现状（进程隔离）。

## 统一设计（新增 ClawTalk/Core/VoiceInput/，5 文件）
1. VoiceInputPhase.swift —— 共用类型：VoiceInputMode（短/长）、VoiceInputPhase（idle/recording/transcribing）、VoiceInputCapture（样本+时长）、VoiceInputGestureAction（cancel/send/transcribe）。
2. VoiceInputGesture.swift —— VoiceInputGestureEvaluator：统一上滑阈值（弧形 50pt / 切长录音 70pt）与微信弧形「角度+距离」命中算法（35~160pt、20°）。
3. VoiceInputSTT.swift —— VoiceInputSTTFactory：统一 STT 工厂（跟随设置 Apple/Doubao 回退 + voiceInputEnabled 开关，与 ClawTalkApp.configureServices 同规则）+ 长录音 50 秒分段工具。
4. LongAudioRecorder.swift —— 长录音录制器（AVAudioEngine+AVAudioFile 流式写盘）从 GlobalVoiceInput.swift 原样迁出（私有改内部）。
5. VoiceInputStateMachine.swift —— 共用状态机（@MainActor @Observable）：
   - 录音：startShort / finishShort（自动转写）/ finishShortCapture（取样本，自定义流程用）/ switchToLong（上滑切长录音，短样本拼接）/ startLong / finishLong / finishLongCapture / cancel / discard / endSession / rebuildSTTService；
   - 阈值与上限与旧实现一致：短 <0.5s 或 ≤8000 样本判误触、短 60s 自动截断、长 <2s 无效、长 60min 上限；
   - 会话生命周期：麦克风权限引导、停唤醒监听、后台任务、转写结束恢复唤醒；
   - 转写：transcribe(samples:chunked:using:) 支持注入 STT（保留各页原 STT 规则）；
   - 回调：onTranscript / onPhaseChange；#if DEBUG 测试接缝 beginRecordingForTesting（保留原测试）。

## 接入点（主 App 侧统一，键盘包不动）
1. GlobalVoiceInput.swift：GlobalVoiceInputViewModel 改为 VoiceInputStateMachine 薄封装，公开 API（mode/state/audioLevel/durationText/waveformLevels/transcript/errorMessage/onTranscript + 6 个录音方法 + discard + 测试接缝）与视图代码零变化；GlobalVoiceInputMode/GlobalVoiceInputState 改为类型别名。→ 11 处 GlobalVoiceInputEmbedded 页面（会议/口述/习惯/提醒/知识库/记账/差旅×3/摘要/写作）与悬浮麦动画行为不变。
2. WeChatInputBar.swift：弧形上滑阈值与「角度+距离」命中改走 VoiceInputGestureEvaluator（常量与算法原值，行为不变），HoldAction 收敛为 VoiceInputGestureAction 别名。
3. ChatViewModel.swift：按住说话（startRecording/stopRecordingAndSend，含 RealtimeVoice 频道）与语音消息（start/stop/cancel/转文字）录音/取消/会话统一走状态机（raw 捕获），STT 保持注入服务 + 豆包流式特例；audioLevel 录音期间取状态机。
4. SyncChatViewModel.swift：语音输入统一走状态机；STT 保持原规则（不过滤 voiceInputEnabled），经 using: 注入。
5. VoiceDiaryViewModel.swift：按住说话 → 状态机（raw 捕获 + 共享 STT 工厂），条目分类/落库/第 4 层联动逻辑不变。
6. FloatingMicViewModel.swift：悬浮球按住说话 → 状态机；公开 API（state/audioLevel/transcript/errorMessage/onTranscript/cancelRecording/restoreWakeListening）不变。
7. AnniversariesView.swift：纪念日按住说话 → 状态机（STT 保持本页 AppleSTTService，经 using 注入），「录音太短」提示保留。
8. AutomationCreateView.swift：自动化语音 → 状态机（STT 保持注入/Apple 回退），点按开始/结束行为不变。
9. 键盘包（KeyboardPackages/HamsterKeyboardKit ClawPanelOverlayView）：只读不动，进程隔离，状态机头注 TODO 不强行合并。
10. 未纳入：Meeting/Dictation/Expense/KB/Habits/Reminder/Travel/Summarize/Writing 的旧自绘按钮为线F遗留惰性死代码（页面实际入口已是 GlobalVoiceInputEmbedded），零删除约束下未触碰；VoiceAssistantViewModel（语音大卡 VAD 连续通话流）不在本批 4 套范围，保留原逻辑（后续可接）。

## 自查
- 逐文件 UTF-8 无 BOM、FFFD=0、括号配对：13/13 通过（新增 5 + 修改 8）。
- 统一后行为一致性核对：录音（按住立即开录/0.3s 长按）/ 上滑（弧形 50pt 命中 / 切长录音 70pt）/ 取消 / 转文字 / 长录音（2s 下限 / 60min 上限 / 50s 分段）/ 误触阈值（0.5s·8000 样本）三套入口共用同一份判定与状态机代码。
- 符号残留检查：LongAudioRecorder / 重复 STT 工厂 / 电平轮询 / 唤醒管理已从各页移除；ChatViewModel 保留的 stopListening 属免提对话流（预期）。
- 单元测试兼容：GlobalVoiceInputTests 引用的 GlobalVoiceInputMode/GlobalVoiceInputState/VM API 全部保留（类型别名 + 测试接缝）。
- git status：本线仅白名单 8 个修改文件 + 新增 ClawTalk/Core/VoiceInput/（其余 M 为并行线在途改动，未触碰）。
- 编译待 CI（本机无 Xcode，xcodegen 自动纳入 ClawTalk/ 新文件）。

## SHA256（当前工作区）
- VoiceInputPhase.swift       845DDB0160576BF17330885AFA29BE523B9022EFEF003816A63B28650D8E14A8
- VoiceInputGesture.swift     FEC4430B7132146CADA7C9048DE9A67D5F83B4752331BB16CF23DD8F6F2764CF
- VoiceInputSTT.swift         EF886DA860902CA0DF45C3D089F2790110BA5D0D8D59683B1AB1A36C9E322365
- LongAudioRecorder.swift     2C19AFA109236D12DA44AD24A023FFABE4B89BBC0FBF32D3B9DC22F9A167EB6D
- VoiceInputStateMachine.swift 81C43974188F7C1DFC03892D96C1E35B1611F69DBAC884C1C42D52B4EB3926B3
- GlobalVoiceInput.swift      2B1C82C8664976575F4C094D70754013C74EB2107F4C046DDAE4591C07DD07D6
- WeChatInputBar.swift        D48C6ACCDAA606AF50331EE6BCD9F4C29835F20E678F83198556E1F880635783
- ChatViewModel.swift         743A34D47EF5963AC634E88806ABD1B1BFCAC157E85F0E0BE0DAF24694594B96
- SyncChatViewModel.swift     37507D09AA346BF2EAD8794B240ECC0CA9949EB6D115712D48EAE3FDD80D5423
- VoiceDiaryViewModel.swift   995020A6E77BFDB17D4EC96772086B257BD1B58D4F9DFAC17251F1EC8CE98088
- FloatingMicViewModel.swift  6E594C11C3E887096FD070923DAC6FB18E1E5FF94EC2FDF896F911B172B9BA91
- AnniversariesView.swift     E7A29F9047FACEE42C09FB087DC69459A8718A6FFB55973FA6E475BFA90F00E5
- AutomationCreateView.swift  8AC26FC20BD002A96ECC39C1BBC98BFECBA32073A9E1D66CDD12C1C20BFC237A

## 风险与注意事项
1. 本线无 Xcode 本地编译，静态自查已通过；编译依赖 CI（xcodegen 会自动纳入 Core/VoiceInput 新文件）。
2. 统一后错误文案有细微收敛：纪念日/自动化「无法开始录音」→ 状态机「麦克风访问失败」；转写失败文案统一为「转写失败：没有识别到内容，请再试一次」（均正常提示，不影响流程）。
3. SyncChatViewModel 保持原 STT 规则（不按 voiceInputEnabled 过滤）经 using: 注入，避免行为变化。
4. 纪念日「录音太短」提示在空样本时也会出现（原实现仅非空样本提示），边缘情况，可接受。
5. 并行线对 GlobalVoiceInput/WeChatInputBar/AnniversariesView 的字体微调改动已保留（本线在其上叠加）。
6. VoiceAssistantViewModel（语音大卡 VAD 流）与键盘包未纳入，后续如需统一可基于本状态机扩展 VAD 钩子。
7. 悬浮球 closePanel 会经 cancelRecording + restoreWakeListening 触发两次唤醒恢复通知，唤醒仲裁幂等，无影响。

## 部署/验证步骤（小强）
1. CI 编译 ClawTalk target 全绿（含 ClawTalkTests 单测：GlobalVoiceInputTests 应通过）。
2. 真机回归：① 聊天页微信弧形按住说话/上滑取消/滑到转文字/语音消息；② 各功能页底部录音区按住/上滑切长录音/松手转写落库；③ 语音日记/悬浮球/纪念日/自动化旧按钮录音→转写；④ 长录音 2s 下限与 60min 上限、切后台继续。