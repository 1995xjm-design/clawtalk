# LINE-S 收尾统一（Design Tokens + Haptics 封装 + 存储统一）交付报告

- 日期：2026-08-15
- 范围：全部只在 `fusion\ClawTalk\ClawTalk` 主 App 内；未动 `KeyboardPackages/`、`ClawTalkTests/`、`ClawTalk/Core/VoiceInput/`（F2 线 5 个文件）、M 线 `SettingsStore/GatewayWebSocket/SecureStorage` 的 bootstrapToken 迁移逻辑。
- 性质：等价重构，功能零删除、零行为变化；未提交、未推送。

## 一、Design Tokens 收敛

改的文件：
- `ClawTalk/App/Theme.swift` —— 新增 `AppTokens` 设计 Token 统一入口：功能卡 8 色语义表、语音录制红、语音大卡顶光带 4 色、5 套语音主题色板（ribbon/accent/background）、3 套内置壁纸色板 + 柔光白、圆角 3 档（small/medium/large）、间距 3 档（small/medium/large）；Markdown 主题代码块圆角改用 `AppTokens.cornerRadiusSmall`。
- `ClawTalk/Features/Home/HomeCardRegistry.swift` —— 14 个功能卡 `tint` 收敛到 8 色语义表：`AppTokens.cardPurple/Pink/Teal/Orange/Green/Indigo/Blue/Red`（原 `.purple/.pink/.teal/.orange/.green/.indigo/.blue/.red` 共 8 色，一一对应，视觉零变化）。
- `ClawTalk/Features/VoiceAssistant/VoiceSceneMode.swift` —— `ribbonColors/accentColor/backgroundColors` 全部收敛到 `AppTokens.voiceXxx*`（aurora/ocean/sunset/forest/mono）。
- `ClawTalk/Features/VoiceAssistant/VoiceAssistantCardView.swift` —— 顶光带 3 色 + 阴影色收敛到 `AppTokens.voiceAuraBlue/Purple/Cyan/BlueShadow`。
- `ClawTalk/Features/Home/GlobalVoiceInput.swift` —— 录制态红色（2 处）收敛到 `AppTokens.voiceRecordingRed`。
- `ClawTalk/Features/Home/HomeWallpaper.swift` —— 3 套内置壁纸色板 + 柔光白收敛到 `AppTokens.wallpaperWarm/Dark/BluePurple/GlowWhite`（色板仍为 `(CGFloat,CGFloat,CGFloat)` 元组，渲染逻辑不变）。

落点：`ClawTalk/App/Theme.swift` 的 `AppTokens`（颜色/圆角/间距）。全部 token 与原来字面值完全一致，零视觉变化；扫描确认主 App 内手写 `Color(red:)` 仅剩 Theme.swift 自身 token 定义与 HomeWallpaper 的动态 `UIColor(red:$0.0,…)` 映射（数据驱动，非手写常量）。

## 二、Haptics 封装

- 新建 `ClawTalk/Core/Utility/Haptics.swift` —— 统一触感入口，4 种标准触感：
  - `Haptics.selection()`（UISelectionFeedbackGenerator 选择）
  - `Haptics.success()`（.success 成功）
  - `Haptics.warning()`（.warning 警告）
  - `Haptics.failure()`（.error 失败）
  - 另提供 `Haptics.impact(_ style:)` 透传 light/medium/heavy，保留录音开始/停止/取消等原有强度语义（等价重构，不改变手感）。
- 全 App 共 18 个调用文件、51 处调用收敛到该入口（`hapticsEnabled` 开关保持原位不动）：

| 文件 | 处数 | 文件 | 处数 |
| --- | --- | --- | --- |
| Core/Gateway/GatewayConnection.swift | 1 | Features/Meeting/MeetingRecorderView.swift | 3 |
| Features/Chat/ChatView.swift | 2 | Features/RealtimeVoice/RealtimeVoiceView.swift | 3 |
| Features/Chat/ChatViewModel.swift | 2 | Features/Safety/EmergencyStore.swift | 2 |
| Features/Chat/InlineMicButton.swift | 3 | Features/Summarizer/SummarizeView.swift | 3 |
| Features/Chat/TalkButton.swift | 4 | Features/VoiceAssistant/VoiceAssistantCardView.swift | 3 |
| Features/Chat/WeChatInputBar.swift | 5（含 selection） | Features/VoiceMessages/VoiceMessageButton.swift | 3 |
| Features/Diary/VoiceDiaryView.swift | 3 | Features/Writing/WritingComposeView.swift | 3 |
| Features/Dictation/DictationRecorderView.swift | 3 | Features/Home/GlobalVoiceInput.swift | 4 |
| Features/Expense/ExpenseListView.swift | 3 | Features/KB/KBView.swift | 3 |

映射：`.success→Haptics.success()`；`.warning→Haptics.warning()`；`.error→Haptics.failure()`；`UISelectionFeedbackGenerator().selectionChanged()→Haptics.selection()`；`.light/.medium/.heavy→Haptics.impact(.x)`；条件式 `willStart ? .medium : .light` 原样透传。

## 三、存储统一（WidgetDataSync 单入口模式）

- `ClawTalk/Core/Storage/ChannelStore.swift` —— `save()`（唯一写入入口）末尾追加 `WidgetDataSync.dataDidChangeNotification` 通知。
- `ClawTalk/Features/Automation/AutomationViewModel.swift` —— `persist()`（唯一写入入口）末尾追加同通知。
- `ClawTalk/Models/GatewayProfile.swift` —— `GatewayProfileStore.persist()`（唯一写入入口）末尾追加同通知；token 仍单独走 `SecureStorage`（Keychain），未触碰 M 线 bootstrapToken 迁移逻辑。

落点：与既有 `ExpenseStore.persist()` / `CareReminderStore.persist()` 完全一致——数据落盘后统一发通知，由 `ClawTalkApp` 的 `onReceive` 触发 `updateWidgetIfNeeded()` → `WidgetDataSync.write(...)` 刷新小组件时间线。存储位置（UserDefaults.standard）、读取路径、数据格式零变化。

## 四、自查结果

- 编码：26 个改动文件全部 UTF-8 无 BOM、FFFD=0（python 字节校验通过）。
- 括号配对：对 HEAD 版本仅叠加本线替换后 `()/[]/{}` 全部平衡；工作区 8 个显示不平衡的文件（ChatView/WeChatInputBar/VoiceDiaryView/DictationRecorderView/ExpenseListView/MeetingRecorderView/RealtimeVoiceView/WritingComposeView）经 HEAD 对比确认为其他线未提交改动引入，非本线导致，未回退、未代修。
- git status：仅新增 `ClawTalk/Core/Utility/Haptics.swift` 一个文件；其余为对既有文件的小型等价修改；未动 `KeyboardPackages/`、`ClawTalkTests/`、`ClawTalk/Core/VoiceInput/`、M 线文件迁移逻辑；未提交、未推送。
- 功能零删除：颜色字面值、触感调用入口、持久化通知均为等价替换/追加。

## 五、改动文件 SHA256（供小强核对部署）

| 文件 | SHA256 |
| --- | --- |
| ClawTalk/App/Theme.swift | 2a533bca5b3f022dac20cb6b842403dff177699572427bb7e8d8f64097323f58 |
| ClawTalk/Features/Home/HomeCardRegistry.swift | 3d533e672f65485eba275750f45ad7bcef2a507d78ae938a0bd0724b6aaac5b1 |
| ClawTalk/Features/VoiceAssistant/VoiceSceneMode.swift | 9d8c687c385cab7e05e1a00da35933909f23eb721404a879261fdd1262ad9fee |
| ClawTalk/Features/Home/GlobalVoiceInput.swift | 32cb0d6b8d53812e1693d066187f705afd0bfa03341bc53346e20c787b96a22c |
| ClawTalk/Features/VoiceAssistant/VoiceAssistantCardView.swift | 1517409aadb09625a2b117c3547da99d885df0104330106323d953d8e72a58cf |
| ClawTalk/Features/Home/HomeWallpaper.swift | 209db17ae4138a7dd36946c9c98ebed69a12694cdba0c8163b58b3355c132d47 |
| ClawTalk/Core/Utility/Haptics.swift（新增） | 1ce2c6a596a9ed45f2859a69c0688c4a838adde965555c0035e3413001477dd2 |
| ClawTalk/Core/Storage/ChannelStore.swift | 5c041302a2f6db99eaba75e3581b9761b1c6862fabdb95a779d078e9701a3d80 |
| ClawTalk/Features/Automation/AutomationViewModel.swift | a0c3732e3979052328eccdd83e1f4e7d32fba585e57adcaaed75f228e18a08d1 |
| ClawTalk/Models/GatewayProfile.swift | 44272b6ca0076be9bb5d5f6db5cd212b6e13756141638671eae7882b3c36ebc0 |
| ClawTalk/Core/Gateway/GatewayConnection.swift | a3d4b41011c48c73167c91e8698112c176161767790af0934b8b439612b896e0 |
| ClawTalk/Features/Chat/ChatView.swift | 04f47238d0bdf4c828b601f58c007907c33c69e3b478331d10b29be8fab84240 |
| ClawTalk/Features/Chat/ChatViewModel.swift | f215e6f484ce0ff93d6bded2d6386279d0df4c1c69baae7e667b0c89352113e3 |
| ClawTalk/Features/Chat/InlineMicButton.swift | 98a3096c8850d63c14fbc8f0e1aa9d9d3a04594eda91d77964c13ba7603ce0b9 |
| ClawTalk/Features/Chat/TalkButton.swift | c26805a09c0aaf94c11cbd23d1c3fe647d4b8d11df088a7394295c218713d453 |
| ClawTalk/Features/Chat/WeChatInputBar.swift | aef9cd18cd9c12a81fab4339265a5b421c46f3e7c6bec76d75b440904f7c3deb |
| ClawTalk/Features/Diary/VoiceDiaryView.swift | 4febe30d1b186f822559f73c2a57d8447f89d3281958a2a391d31d1f61ccead4 |
| ClawTalk/Features/Dictation/DictationRecorderView.swift | d922d2d90017d4388e0d73a70de641cfb3da6288a1cd2ead6df39576ff66c1f0 |
| ClawTalk/Features/Expense/ExpenseListView.swift | 7bf53fe4ca7f534f713840e042e86c39d31796b31520cf87e293a622dfef3b23 |
| ClawTalk/Features/KB/KBView.swift | 8c08f61126595f5eea8cad1980ed2c7b783e2b37664f413a3e227e55e2b732b6 |
| ClawTalk/Features/Meeting/MeetingRecorderView.swift | 7047519b62a3591b13ddf0cb7085681376346202c3c0850b8442dea7b8ca3d79 |
| ClawTalk/Features/RealtimeVoice/RealtimeVoiceView.swift | 63a455d4f20da8e891c1362611ff8c531ecd0dc70007f54739f60850b3720fd4 |
| ClawTalk/Features/Safety/EmergencyStore.swift | 63b38c86cc3aad82ac493057d19efef739a42b843336685f4f353b321ece52dc |
| ClawTalk/Features/Summarizer/SummarizeView.swift | 8f98f481cbdae563c18448b79da9ed1bd27c2e8b910c4f39b3a932b16fd1e698 |
| ClawTalk/Features/VoiceMessages/VoiceMessageButton.swift | cbcb54ef7b1299e362f1f7a9fb3e7ee875c523228bf51ea8c7850686a20ddfe5 |
| ClawTalk/Features/Writing/WritingComposeView.swift | 0748eb6b3a2baf30c15459bab7b61e5ae87ca33894362e8fb4ed8e9523e691db |