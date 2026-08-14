# LINE-N Accessibility Labels Report (ClawTalk Main App)

## Task Overview

Add accessibilityLabel / accessibilityValue / accessibilityHint to all custom interactive controls in the ClawTalk main app source (ClawTalk/, excluding KeyboardPackages/ and ClawTalkTests/): home cards, record/voice buttons, icon buttons, and tab switching. Add-only change: no functionality, layout, or visual code was modified. Components that already had accessibility modifiers were skipped. Labels are concise Chinese.

## Files Changed (36) and Accessibility Modifiers Present

The list below is extracted live from each modified file (all .accessibility* modifiers on the touched controls):

- `ClawTalk/Features\Home\HomeCard.swift`
  L59: .accessibilityLabel("\(card.title)卡片")
  L60: .accessibilityValue(card.summary)
  L61: .accessibilityHint("点按进入\(card.title)功能页")

- `ClawTalk/Features\Home\ExpenseCardView.swift`
  L64: .accessibilityLabel("语音记账卡片")
  L65: .accessibilityValue(summaryText)
  L66: .accessibilityHint("点按打开语音记账")

- `ClawTalk/Features\Home\HomeTabView.swift`
  L112: .accessibilityLabel("实时语音")
  L182: .accessibilityLabel("编辑卡片")
  L193: .accessibilityLabel("管理卡片")
  L293: .accessibilityHint("打开\(kind.title)功能页")
  L362: .accessibilityLabel("移除\(kind.title)卡片")
  L379: .accessibilityLabel("调整\(kind.title)卡片尺寸")

- `ClawTalk/Features\Home\HomeCardManagerView.swift`
  L49: .accessibilityValue(enabled.contains(kind) ? "已显示" : "已隐藏")

- `ClawTalk/Features\Chat\WeChatInputBar.swift`
  L54: .accessibilityLabel(isVoiceMode ? "切换键盘输入" : "切换语音输入")
  L70: .accessibilityLabel("发送")
  L80: .accessibilityLabel("添加附件")
  L119: .accessibilityLabel(isRecording ? "停止录音" : "按住说话")
  L120: .accessibilityHint("按住开始录音，松开发送；上滑选择取消或转文字")

- `ClawTalk/Features\Chat\MessageBubble.swift`
  L60: .accessibilityLabel("重新播放语音")

- `ClawTalk/Features\VoiceMessages\VoiceMessageBubble.swift`
  L83: .accessibilityLabel(player.playingID == attachment.id ? "停止播放" : "播放语音")
  L84: .accessibilityValue(Self.durationText(attachment.duration))

- `ClawTalk/Features\Chat\ChatView.swift`
  L121: .accessibilityLabel(viewModel.isConversationMode
  L143: .accessibilityLabel("更多操作")
  L314: .accessibilityLabel("删除图片")
  L341: .accessibilityLabel("移除附件")
  L434: .accessibilityLabel("停止朗读")

- `ClawTalk/Features\Sync\SyncChatView.swift`
  L174: .accessibilityLabel("刷新")
  L193: .accessibilityLabel("更多操作")
  L352: .accessibilityLabel("删除图片")
  L379: .accessibilityLabel("移除附件")

- `ClawTalk/Features\Writing\WritingComposeView.swift`
  L648: .accessibilityLabel("关闭")
  L704: .accessibilityLabel("删除要点")
  L916: .accessibilityLabel(accessibilityLabel)

- `ClawTalk/Features\RealtimeVoice\RealtimeVoiceView.swift`
  L49: .accessibilityLabel("关闭")
  L141: .accessibilityLabel(session.state == .recording ? "正在聆听，松开发送" : "按住说话")

- `ClawTalk/Features\Diary\VoiceDiaryView.swift`
  L77: .accessibilityLabel("关闭")
  L252: .accessibilityLabel(accessibilityLabel)

- `ClawTalk/Features\Dictation\DictationRecorderView.swift`
  L303: .accessibilityLabel("关闭")
  L494: .accessibilityLabel(accessibilityLabel)

- `ClawTalk/Features\Meeting\MeetingRecorderView.swift`
  L318: .accessibilityLabel("关闭")
  L517: .accessibilityLabel(accessibilityLabel)

- `ClawTalk/Features\Expense\ExpenseListView.swift`
  L348: .accessibilityLabel("关闭")
  L472: .accessibilityLabel(recordAccessibilityLabel)

- `ClawTalk/Features\CloneTalk\CloneTalkView.swift`
  L58: .accessibilityLabel("关闭")

- `ClawTalk/Features\Anniversaries\AnniversariesView.swift`
  L77: .accessibilityLabel("添加纪念日")

- `ClawTalk/Features\Automation\AutomationListView.swift`
  L60: .accessibilityLabel("新建任务")

- `ClawTalk/Features\Habits\HabitsView.swift`
  L95: .accessibilityLabel("新建习惯")

- `ClawTalk/Features\HomeCare\ReminderListView.swift`
  L108: .accessibilityLabel("新建提醒")

- `ClawTalk/Features\Geofence\GeofenceListView.swift`
  L35: .accessibilityLabel("添加地理围栏")

- `ClawTalk/Features\Travel\TravelListView.swift`
  L76: .accessibilityLabel("新增出行")

- `ClawTalk/Features\Channels\ChannelListView.swift`
  L220: .accessibilityLabel("打开设置")
  L228: .accessibilityLabel("打开工具")

- `ClawTalk/Features\Canvas\CanvasView.swift`
  L27: .accessibilityLabel("复制链接")

- `ClawTalk/Features\KB\KBView.swift`
  L216: .accessibilityLabel("发送问题")
  L363: .accessibilityLabel(accessibilityLabel)

- `ClawTalk/Features\Tools\TerminalView.swift`
  L87: .accessibilityLabel("发送命令")
  L102: .accessibilityLabel("停止执行")
  L109: .accessibilityLabel("清空终端记录")

- `ClawTalk/Features\Settings\DiagnosticsView.swift`
  L188: .accessibilityLabel("刷新修复建议")

- `ClawTalk/Features\Settings\VoiceSettingsView.swift`
  L266: .accessibilityLabel("删除唤醒词")

- `ClawTalk/Features\Settings\GatewayHeadersView.swift`
  L39: .accessibilityLabel("删除请求头")

- `ClawTalk/Features\Settings\SkinSettingsView.swift`
  L68: .accessibilityLabel("无壁纸（默认纯色）")
  L96: .accessibilityLabel("选择壁纸\(id + 1)")
  L313: .accessibilityLabel("灵动岛样式预览：\(style.displayName)")

- `ClawTalk/Features\Parking\ParkingView.swift`
  L305: .accessibilityLabel("导航到停车位置")
  L316: .accessibilityLabel("添加停车照片")

- `ClawTalk/Features\FamilyShare\FamilyShareListView.swift`
  L41: .accessibilityLabel("刷新")

- `ClawTalk/Features\Tools\ScreenStreamView.swift`
  L57: .accessibilityLabel("停止轮询")
  L102: .accessibilityLabel("刷新画面")

- `ClawTalk/Features\Tools\FileTransferView.swift`
  L90: .accessibilityLabel("刷新")
  L552: .accessibilityLabel("下载文件")

- `ClawTalk/Features\FloatingMic\FloatingMicView.swift`
  L96: .accessibilityLabel("语音助手")
  L97: .accessibilityHint("点按打开语音助手面板")
  L205: .accessibilityLabel("按住说话")

- `ClawTalk/Features\VoiceAssistant\VoiceAssistantCardView.swift`
  L97: .accessibilityLabel("随身语音助手，\(statusText)。轻点开始或结束对话，长按退出，右上角切换场景与语音设置。")
  L316: .accessibilityLabel("对话记录")
  L327: .accessibilityLabel("语音设置")
  L338: .accessibilityLabel("切换场景模式，当前\(viewModel.sceneMode.displayName)")
  L376: .accessibilityLabel(gatewayDotAccessibilityText)

## Changes by Category

- Home cards: `HomeCard.swift` (card label + value + hint), `ExpenseCardView.swift` (label + value + hint), `HomeTabView.swift` (card link hint), `HomeCardManagerView.swift` (card visibility value).
- Record/voice buttons: `WeChatInputBar.swift` (hold-to-talk label + hint), `MessageBubble.swift` (replay label), `VoiceMessageBubble.swift` (play/stop label + duration value); close (xmark) buttons labeled in `VoiceDiaryView`, `DictationRecorderView`, `MeetingRecorderView`, `ExpenseListView`, `CloneTalkView`, `WritingComposeView`, `RealtimeVoiceView`.
- Icon buttons: chat (more-actions menu, remove image, remove attachment, stop speaking in `ChatView`; same remove buttons in `SyncChatView`), toolbar add buttons (`AnniversariesView`, `AutomationListView`, `HabitsView`, `ReminderListView`, `GeofenceListView`, `TravelListView`), `ChannelListView` (settings/tools), `CanvasView` (copy link), `KBView` (ask), `TerminalView` (send command), `DiagnosticsView` (refresh), `VoiceSettingsView` (remove wake word), `GatewayHeadersView` (remove header), `SkinSettingsView` (wallpaper tiles), `ParkingView` (navigate/photo), `FamilyShareListView` (refresh), `ScreenStreamView` (refresh), `FileTransferView` (download), `FloatingMicView` (assistant ball label + hint).
- Tab switching: main TabView uses Label(text+systemImage) and `SessionsView` segmented picker uses Text; both are already announced by VoiceOver, so no changes were made.

## Self-Check Results

- Encoding: all 36 changed files are UTF-8 without BOM; programmatic scan found 0 U+FFFD replacement characters.
- Bracket pairing: { } ( ) [ ] balanced in every changed file (strings and comments excluded).
- Add-only: git diff shows only added .accessibility* lines from this task; other +/- in the same files are pre-existing concurrent changes (fonts/voice/permissions lines) that were not touched.
- Line endings preserved: CRLF files stay CRLF, LF files stay LF, ParkingView keeps its original mixed style.
- Not committed, not pushed.

## SHA256 (Changed Files)

```
dd80459c480184f138d4f9b300873d5fe68c1a0ddfab0a8226661a7b45ec1590  ClawTalk/Features\Home\HomeCard.swift
f9088b7674162a64bff83ab9867a1bc44fb8a71b5d72b8f42463cf6a7fddd3af  ClawTalk/Features\Home\ExpenseCardView.swift
1648827a411d37c8071fa9239207a3dc69cb6d6884bc2022501dbfeab2e96b18  ClawTalk/Features\Home\HomeTabView.swift
044d99cbe585b1cc9b3d28767080d87f0dc43bedd76f820ffb5cd5a81237646b  ClawTalk/Features\Home\HomeCardManagerView.swift
aef9cd18cd9c12a81fab4339265a5b421c46f3e7c6bec76d75b440904f7c3deb  ClawTalk/Features\Chat\WeChatInputBar.swift
3b8dc8068e95fcfd17c0a9038649287f943df09e206c65ee65e63a10943fc308  ClawTalk/Features\Chat\MessageBubble.swift
1fb1212937a6307edfee83c23c9e3f68e25776466fe3dbb0436f3fdfeaf1200d  ClawTalk/Features\VoiceMessages\VoiceMessageBubble.swift
04f47238d0bdf4c828b601f58c007907c33c69e3b478331d10b29be8fab84240  ClawTalk/Features\Chat\ChatView.swift
c78ed41e94f8845f60211a8f37ceab8fb03a85987774bef7cfd9b41ce95a4c9b  ClawTalk/Features\Sync\SyncChatView.swift
0748eb6b3a2baf30c15459bab7b61e5ae87ca33894362e8fb4ed8e9523e691db  ClawTalk/Features\Writing\WritingComposeView.swift
63a455d4f20da8e891c1362611ff8c531ecd0dc70007f54739f60850b3720fd4  ClawTalk/Features\RealtimeVoice\RealtimeVoiceView.swift
4febe30d1b186f822559f73c2a57d8447f89d3281958a2a391d31d1f61ccead4  ClawTalk/Features\Diary\VoiceDiaryView.swift
d922d2d90017d4388e0d73a70de641cfb3da6288a1cd2ead6df39576ff66c1f0  ClawTalk/Features\Dictation\DictationRecorderView.swift
7047519b62a3591b13ddf0cb7085681376346202c3c0850b8442dea7b8ca3d79  ClawTalk/Features\Meeting\MeetingRecorderView.swift
7bf53fe4ca7f534f713840e042e86c39d31796b31520cf87e293a622dfef3b23  ClawTalk/Features\Expense\ExpenseListView.swift
34444e58e89ec6c288d1474c5479fb3dfa2dd155c6777f079b61c9727a286a5f  ClawTalk/Features\CloneTalk\CloneTalkView.swift
62e10785293c3a3d352b1ff67c2e36af0e05d3dbc6aa6a0c92092351c31a40b5  ClawTalk/Features\Anniversaries\AnniversariesView.swift
d1b8cd5cb6e35b706d108bc254a7e452901fad579f708270b8139538280e83d8  ClawTalk/Features\Automation\AutomationListView.swift
1eb12e296751d945f646d22bc929b5e9fc13347ce7f235cb85274eb9a54eee22  ClawTalk/Features\Habits\HabitsView.swift
3b35cfcbca74ee711e6ec2a3a58eec4ce3280fecdcfc28217e40d16aed248629  ClawTalk/Features\HomeCare\ReminderListView.swift
035e9b58691164dc030b69f99795fe54f1a28b7becafa3a60065fb67be0c08b8  ClawTalk/Features\Geofence\GeofenceListView.swift
d571c1c78b84208b8a6130396c029f27ef3a062a34b268c6dbb656eb44673ee5  ClawTalk/Features\Travel\TravelListView.swift
d6b099337fbe4ab68774efddf37f5221bc4136836c2cba86c860c8df747bec0e  ClawTalk/Features\Channels\ChannelListView.swift
8d890896c9df63eabe76aa155389b39371655b3e88b3650a7f5099b03597cd74  ClawTalk/Features\Canvas\CanvasView.swift
298ee39003bb92bb8c768f8cf9f4d618746035812fa77074afd53392b0b971df  ClawTalk/Features\KB\KBView.swift
bb748610866a61772a690ce8e1b8dfe4e36893943ac258af73fdb240d7458962  ClawTalk/Features\Tools\TerminalView.swift
55a1092e818690790b1b36db9978b988304257d73d4a28d3179f0994a89c5a7f  ClawTalk/Features\Settings\DiagnosticsView.swift
17033fa9b5dd3c7895e8df138ae34bf1f456599c491d6588dba6719ced394e45  ClawTalk/Features\Settings\VoiceSettingsView.swift
f70ee9fbc435209a713c26362e2e5ee5def2389e002ab2d689ebabd898bf789a  ClawTalk/Features\Settings\GatewayHeadersView.swift
3f473f71d3e5607b74947694961ac0b1425492e7e683decce5e2a7ca3a159aa3  ClawTalk/Features\Settings\SkinSettingsView.swift
1ea210ad401cd3fa3ca194a7661bef5952cb02a6e9a238ae24d63e5d0a2722a9  ClawTalk/Features\Parking\ParkingView.swift
302b46cfb3679bdfbb0ec678a31045789c202035142f9f98fec6499de9df0234  ClawTalk/Features\FamilyShare\FamilyShareListView.swift
24f9c13e7d049b8f634a0fbb1d4afe8397d21cd4150672216955bd851e78ff27  ClawTalk/Features\Tools\ScreenStreamView.swift
106d1d6391b6fcad1663e1b84c54dce140ed522755d841fe9f44bf53e0d2128a  ClawTalk/Features\Tools\FileTransferView.swift
bcb398b7e6f2b4abfc9d3dacb66aea3c0d3013123490c5950191639a801c03ce  ClawTalk/Features\FloatingMic\FloatingMicView.swift
1517409aadb09625a2b117c3547da99d885df0104330106323d953d8e72a58cf  ClawTalk/Features\VoiceAssistant\VoiceAssistantCardView.swift
```

## Deployment Notes

View-layer modifiers only: no migration, no configuration, no data changes. Ships with the next normal build; no special steps required.

