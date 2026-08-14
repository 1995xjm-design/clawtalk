# REVIEW-STANDARDS-20260815 代码审查（Standards 轴）

- 审查范围：`git diff 2d05e1d`（v049n 全批次 + 未提交 I/J/L5 改动，61 文件，约 3443 行新增）+ 未跟踪文件 `ClawTalk/Features/DailyBriefing/WeatherService.swift`
- 审查方式：只读，未改任何代码，未提交
- 对照标准：Fowler《Refactoring》ch.3 代码气味 + 仓库 AGENTS.md（中文注释 / UTF-8 / 诚实原则 / 功能零删除）
- 编码核查：抽查 ChatView.swift / WeatherService.swift 字节级均为合法 UTF-8，控制台乱码仅为 GBK 显示问题，非文件问题
- 结论：2 个 critical（编译必失败 + 照片数据丢失）、1 个 major（天气 Key 双源不一致）、若干 info

---

## CRITICAL（必须修，阻断交付）

### C1. ChatView.swift:584 / ChatView.swift:615 - `ChatMessageRow` 重复声明，编译必失败
- 问题：同一文件内两个完全相同且均为 `private struct ChatMessageRow: View`，Swift 报 `invalid redeclaration of 'ChatMessageRow'`，工程无法编译（v049n 合批时复制粘贴残留）。
- 建议：删除其中一份（584-613 或 615-644 内容一致，保留其一），并确认 ChatView 列表处引用正常。

### C2. ExpenseStore.swift:156 - 字符串插值写错，照片文件名恒为同一字面量，互相覆盖
- 问题：`let name = "expense-\\(UUID().uuidString.prefix(8).lowercased()).jpg"` 中 `\\(` 是「转义反斜杠 + 左括号」，不是插值。实际文件名恒为字面量 `expense-\(UUID().uuidString.prefix(8).lowercased()).jpg`：
  - 所有带照片的账目写到同一文件，后保存的覆盖先保存的（数据丢失）；
  - 删除任一含照片账目时 `deletePhoto` 会删掉共享文件，其余账目照片同时丢失；
  - 对照 ParkingStore.swift:142 的正确写法 `"parking-\(UUID().uuidString.prefix(8).lowercased()).jpg"`。
- 建议：改为 `"expense-\(UUID().uuidString.prefix(8).lowercased()).jpg"`，与 ParkingPhotoStore 写法对齐。

## MAJOR（高优先级，功能缺陷）

### M1. 天气 API Key 双源不一致：设置页改 Key 后播报不生效，直到重启
- 问题：
  - SettingsView.swift:22 `@State weatherAPIKey` + :102 `onChange` 直接写 `SecureStorage`（key `weather_api_key`）；
  - SettingsStore.swift:31 另有 `weatherAPIKey` 属性（didSet 同步钥匙串），但只在 init（:57）读一次，无刷新路径；
  - DailyBriefingView.swift:184 播报时读的是 `settings.weatherAPIKey`（SettingsStore 副本）。
  - 结果：用户在「设置 > 每日播报 · 天气」填 Key 后，SecureStorage 已更新，但 SettingsStore 仍是启动时旧值，播报继续显示「天气未配置 API Key」，直到 App 重启。
- 建议：SettingsView 的 SecureField 直接绑定 `store.weatherAPIKey`（SettingsStore 已有 didSet 落钥匙串），删掉本地 @State + onChange 双写；同文件 deepSeekKey 是既有同款问题，可一并收敛。

## INFO（建议，按价值排序）

### I1. 重复代码（Duplicated Code）
- **ExpensePhotoStore 整段拷贝**：ExpenseStore.swift:138-168 与 ParkingStore.swift:128-157 几乎逐行相同（注释自认「复用 ParkingPhotoStore 模式」），且拷贝时引入 C2 的插值 bug。建议抽公共 `PhotoFileStore`（目录名参数化）或让 ExpensePhotoStore 复用通用实现。
- **Middle Man**：ExpenseStore.swift:102/107/112 `savePhoto/deletePhoto/photoURL` 三层透传给 ExpensePhotoStore，视图层可直接依赖 ExpensePhotoStore；若保留 Store 门面，建议只留一个入口（如 `savePhoto`）。
- **OCR/语音关键词双表**：ExpenseCameraPicker.swift:121-143 的 `category(from:)` 规则表与 ExpenseVoiceParser.swift:143-153 相同，:138 `incomeKeywords` 与 ExpenseVoiceParser.swift:153 相同（注释自认「同表」）。建议把关键词表提到 ExpenseVoiceParser 公开静态常量，OCR 解析器直接复用，避免只改一处导致两路识别结果漂移。
- **相册读取逻辑重复**：ExpenseListView.swift:740 `loadPickedPhoto` 与 :759 `loadManualPhoto` 结构几乎相同（仅错误目标变量不同），可合并为 `loadPhoto(item:onError:)`。
- **照片加载逻辑重复**：ExpenseListView.swift `ExpensePhotoViewer.load()`（:1065 附近）与 `ExpensePhotoThumbnail.load()`（:1109 附近）相同（url -> Data(contentsOf:) -> UIImage），建议并入 ExpensePhotoStore 提供 `image(fileName:)`。
- **小组件记账文案重复**：ClawTalkFunctionWidgets.swift:125 `expenseContent(_:)` 与 ClawTalkSwitchableWidget.swift:154 `expenseContent` 逻辑相同（「本月：…\n今日：…」）。建议移到共享文件（如 ClawTalkShared）只留一份。
- **小组件 TimelineProvider 骨架重复**：ClawTalkSwitchableWidget.swift:38-79 与 ClawTalkTimelineProvider.swift 的 placeholder/snapshot/timeline（15 分钟策略）同构，可抽公共 provider 基类。
- **bottomArea 模板散落约 9 文件**：`VStack { List; Divider().opacity(0.3); bottomArea(GlobalVoiceInputEmbedded) }` 以「与长文摘要页一致」注释复制到 KBView.swift:248、HabitsView.swift:139、ReminderListView.swift:143、TravelListView.swift:199/396、ExpenseListView.swift:316、DictationRecorderView.swift:369、MeetingRecorderView.swift:392（模板源 SummarizeView.swift:754、WritingComposeView.swift:786）。建议抽 `BottomVoiceAreaContainer` 通用容器，一处改动全页面生效。
- **5 套主题动画外壳重复**：VoiceAssistantCardView.swift 的 AuroraFlowLayer/OceanDiveLayer/SunsetPulseLayer/ForestBarLayer/StardustLayer 共享 TimelineView + GeometryReader + ambientLevel 外壳，且 stateSpeedMultiplier/stateBrightnessMultiplier 两个 switch（:735-759）随 state 新增 case 需同步。可抽 `ThemeTimelineContainer` 只注入绘制闭包，两套系数函数并入状态扩展。
- **键盘视图骨架重复**：新文件 ChineseNineGridIOSKeyboard.swift（170 行）与 ChineseNineGridKeyboard.swift 的 init/combine/setupKeyboardView/layoutSubviews 结构基本一致，仅布局引擎与配色不同。若后续还要加键盘形态，建议先抽公共基类（当前可接受，提示风险）。

### I2. Feature Envy / 魔法字符串（跨 Store 直读持久化 key）
- WidgetDataSync.swift:85 硬编码 `"expense_entries_v1"`（= ExpenseStore.swift:21 `defaultsKey` 的私有两份），:94 硬编码 `"clawtalk_parking_records_v1"`（= ParkingStore.swift 的 `storageKey`）。Store 一旦迁移 key，小组件静默变空。建议 ExpenseStore/ParkingStore 暴露只读静态入口（或把 key 常量公开），WidgetDataSync 走公开 API 而非复制 key。

### I3. Repeated Switches
- **ExpenseType 收支累加**：`switch entry.type { case .income/.expense }` 累加逻辑出现在 WidgetDataSync.swift:44-57（两处）、ExpenseXLSXExporter.swift（detailSheet 与 categorySheet 两处）。建议 `ExpenseEntry` 增加 `var isIncome: Bool`，消除 switch 漂移。
- **HomeCardKind 新增 case 的散点同步**：加一张卡片要改 HomeCardRegistry.swift 4 个 switch（title/icon/color/subtitle）+ HomeMergedCard.swift:272 sections switch + HomeTabView.swift:325 if/else 链 + :481 overviewText switch。建议把「目的地视图」收敛到 HomeCardRegistry 统一注册，if/else 链最易漏（漏了新 case 会静默回退到 HomeMergedCardPage，编译不报错）。
- **ClawTalkCardOption**：ClawTalkSwitchableWidget.swift 的 `caseDisplayRepresentations` 字典与 :100 的渲染 switch 需同步；加卡片要改两处。可让枚举自带 displayRepresentation 计算属性。

### I4. Speculative Generality / 死代码
- GatewayCronClient.swift:274 `webSocketRPC` 枚举 case 永不产出（probeEndpoints 只设 restTasks/restList，注释说「本端仅标记不实现」），属占位投机。要么实现，要么删除。
- VoiceSceneMode.swift `displayName`（:284-293）注释自认「代码检索/调试用」，仅 5 处字符串映射，价值低，可并入 waveform 的 displayRepresentation。
- ExpenseListView.swift ExpenseExportScope 的 `id` 与 `title` 都等于 rawValue（:998-1002），冗余；二选一即可。

### I5. 实际问题
- **表演性加载延迟**：ChatViewModel.swift:1081 `Task.sleep(250ms)` 制造「正在加载更早消息…」展示（数据已在内存，属人为延迟）。诚实性 OK，但建议改为即时展开 + 用转场动画呈现窗口变化。
- **DateFormatter 每次新建**：ClawTalkApp.swift:1047 `nextReminderWidgetText` 每次调用 new DateFormatter()，而该方法在 3 秒同步循环 + 各通知里高频调用。建议改静态 formatter。
- **调试日志残留**：ChineseNineGridKeyboard.swift `collectionView(_:didSelectItemAt:)` 内 `Logger.statistics.warning("change input text handle = \(handle)")` 每次点符号都打 warning 日志（Hamster 原版残留）。建议降级为 debug 或删除。
- **录音页死代码**：DictationRecorderView.swift:424/459、MeetingRecorderView.swift:447/482 的 `statusLabel/recordButton`（含 isPressed/holdTimer 等状态）在 recordArea 换用 GlobalVoiceInputEmbedded 后已不可达。FIX-F-20260814 报告声明是「功能零删除」约束下的惰性死代码，可接受；建议后续用编译标记包裹或加注释说明。
- **新文件缺末尾换行**：ExpenseCameraPicker.swift / ExpenseListView.swift / ExpenseXLSXExporter.swift / ClawTalkSwitchableWidget.swift / ClawTalkWidgetBundle.swift 等 `\ No newline at end of file`，按仓库习惯补上。
- **天气城市空值瑕疵**：DailyBriefingEngine.swift `currentWeather()` 只 guard API Key，不 guard 城市；DailyBriefingView.swift:184 直传 `settings.weatherCity`，用户清空城市时会报「天气读取失败」而非「城市未配置」。可在引擎内显式判空并给出对应 skipNote。
- **WidgetDataSync.expenseSummaries 返回值**：`(today: String, month: String, legacy: String)` 元组（:38）含三个语义不同的字符串，建议改小结构体，避免调用方（ClawTalkApp.swift:1034-1037）按位置解包时错位。

### I6. 命名（Mysterious Name）
- **已改进**：`appURLForGuru` 改 `appURLForClawTalk`、`navigateToGuru` 改 `navigateToClawTalk`（HamsterConstants.swift / SettingsRootView.swift / SettingsViewModel.swift），全局无旧名残留，命名更达意。
- **待改进**：WidgetDataSync.swift:13 `expenseKey` 实际存「本月支出/收入」legacy 行（`legacyExpenseLine`），与新增的 expenseTodayKey/expenseMonthKey 语义重叠，易误用。建议改名 `expenseLegacyKey` 或与小组件侧统一。

### I7. 诚实验证抽查（未发现造假）
- WidgetDataSync.swift / ExpenseCameraPicker.swift / ExpenseListView.swift / DailyBriefing 天气链路均按「无数据 -> 诚实空态/skipNote」处理，未发现假数据；HomeCardRegistry 迁移幂等（migratedKey 防重入）。
- 主线程重活已移后台：KeyboardSettingsHostViewController.loadSettingsAsync 将容器初始化放到 global queue。
- diff 新增行未发现 `as!`/强制解包残留。
