# FIX-F-VOICE-20260814 线F 语音页统一（长文摘要模板）

## 根因/背景
- 10 个语音功能页录音入口样式/位置不统一：会议纪要、文档口述、语音日记仍用各页自绘旧录音按钮；
  习惯打卡、提醒、知识库、语音记账、差旅把 GlobalVoiceInputEmbedded 放在列表顶部或输入区，与长文摘要页（底部固定录音区）不一致。
- 目标：以 SummarizeView 为模板（VStack { 内容; Divider; bottomArea(GlobalVoiceInputEmbedded) }）统一各页，
  复用现有 GlobalVoiceInputViewModel 转写流程，onTranscript 回调接各页原有落库逻辑，功能零删除。

## 改动清单（8 文件，全部在白名单内）
1. ClawTalk/Features/Meeting/MeetingRecorderView.swift
   - 新增 private let settingsStore 属性（init 赋值）；recordArea 换成 GlobalVoiceInputEmbedded，
     onTranscript -> viewModel.transcript = trimmed（复用现有 transcript 落库/整理纪要流程）。
   - 旧自绘 recordButton/statusLabel/手势代码保留为惰性死代码（不影响编译与渲染）。
2. ClawTalk/Features/Dictation/DictationRecorderView.swift
   - 同上：recordArea 换 GlobalVoiceInputEmbedded，onTranscript -> viewModel.transcript = trimmed。
3. ClawTalk/Features/Diary/VoiceDiaryView.swift
   - 底部结构已符合模板；VoiceDiaryViewModel 无公开文本落库接口（白名单不含 VM），
     按约束保留原录音按钮并在 recordArea 标注 TODO(线F) 说明后续接法。
4. ClawTalk/Features/Habits/HabitsView.swift
   - 语音入口从 List 顶部 Section 移到页面底部固定录音区（Divider + bottomArea），
     onTranscript -> applyVoiceText（原有语音打卡逻辑不变）；空状态文案「上方按钮」改「底部按钮」。
5. ClawTalk/Features/HomeCare/ReminderListView.swift
   - 同上移到底部；通知权限被拒横幅从 safeAreaInset 并入 bottomArea（逻辑不变）。
6. ClawTalk/Features/KB/KBView.swift
   - 语音入口从输入区卡片移到页面底部固定录音区；onTranscript -> query="" + store.ask(text)（原有逻辑不变）。
7. ClawTalk/Features/Expense/ExpenseListView.swift
   - 语音入口从顶部操作区移到页面底部固定录音区；「没听清金额」alert 随组件移到 bottomArea；
     手动添加/错误提示留在顶部；onTranscript -> handleExpenseTranscript（原有解析确认保存流程不变）。
   - 注：并行线 G 曾同时改写本文件并中途回退，本线在其回退后重新应用，最终状态=HEAD+线F改动，括号平衡。
8. ClawTalk/Features/Travel/TravelListView.swift
   - 列表页：语音入口移到底部固定录音区（onTranscript -> applyVoiceText）。
   - 详情页 TravelDetailView：voiceUpdateSection 从列表内移到底部固定录音区（onTranscript -> applyVoiceUpdate）；
     voiceUpdateSection 函数保留为惰性死代码。

未改动：SummarizeView / WritingComposeView（已完全符合模板）；DictationListView / MeetingListView / WindDownView
（无语音输入/录音，白名单条件「实际存在且含语音输入或录音」不满足）；GlobalVoiceInput.swift（组件本身无需改动，
线 D 的加固 diff 保持不动）。

## 自查
- 逐文件 UTF-8 无 BOM、FFFD=0、{} 与 () 配对、无负深度：8/8 通过（含记账页重新应用后复验）。
- 各页 bottomArea 唯一、GlobalVoiceInputEmbedded 引用数量符合预期（Travel=2 处 bottomArea + 1 处遗留 voiceUpdateSection）。
- git status：本线改动仅限上述 8 个白名单文件（其余 M/?? 为并行 A/C/D/E/G/H 线的在途改动，未触碰）。
- 转写落库接口全部复用现有（transcript / applyVoiceText / applyVoiceText / store.ask / handleExpenseTranscript /
  applyVoiceUpdate / applyVoiceText），无新增存储逻辑，功能零删除。
- 悬浮麦不挡字：底部录音区为 VStack 固定区（非 overlay），内容区 maxHeight 自适应，不会与文字重叠；
  各页按模板加 .padding(.vertical, 10) 底部适配。

## SHA256（当前工作区）
- MeetingRecorderView.swift      B2F3B5883DF4E01DB86991F7AEA831C769DFE08A80808C63B5FE43A475A0E329
- DictationRecorderView.swift    81FD90804B2C373F48C126EB91DF88BC4309EF4119FDB5F6D5592C24D8FAA8CF
- VoiceDiaryView.swift           32A39B214B629032E7A3376458506E4964C757E98C7531652D605D8B6F2F20FB
- HabitsView.swift               C2711AED2DDC591016C0ADE18C03375CD24B9E532239BFD24AF9A2ABF168A797
- ReminderListView.swift         30B5036175F5D92E3589169AF6D18E6B4814284B64D2FD1C60C6FA175FF22DC0
- KBView.swift                   E08F988991D7E0B366C52AECC1414800D9AA32FA57FD5C1E5256A256C56213D5
- ExpenseListView.swift          C24F15F13BB162D7D340A01DB9153DA632C1875A12CF031AF8F2C797FB09B0C5
- TravelListView.swift           80C989479BB5F2050577F50A7400C694C8BCC102856017DB66E7EBF912FC915B

## 风险与注意事项
1. 并行线 G 曾与线 F 同时在 ExpenseListView.swift 上作业，中途整文件回退/重写（曾出现 0 字节与缺右括号状态）；
   最终线 G 回退该文件、线 F 在其上重新应用完成（HEAD+线F），当前括号平衡、FFFD=0。
   主线程合并时若线 G 再次改动该文件，需按线 F 模板（底部 bottomArea）对齐，避免把语音入口放回顶部。
2. VoiceDiaryView 保留旧录音按钮（VM 无文本接口，白名单不含 VM），已标 TODO，后续需在
   VoiceDiaryViewModel 增加 process(transcript:) 再统一。
3. 会议/口述/差旅详情页保留旧自绘按钮/voiceUpdateSection 惰性死代码（避免删减引入编译风险），可后续清理。
4. 本线无法本地编译（无 Xcode），已做静态自查，编译验证依赖 CI。

## 部署/验证步骤（小强）
1. CI 编译 ClawTalk target 全绿（重点：ExpenseListView 与线 G 合并后）。
2. 真机回归：各页底部按住说话→转写→落库/整理；录音中悬浮麦动画；底部不挡列表文字；提醒页通知权限横幅位置。