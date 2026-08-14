# 代码审查报告 · Spec 轴（v049n 全批次 + 未提交 I/J/L5）

- 审查范围：`git diff 2d05e1d`（61 文件，+3443/-271；基线 2d05e1d → 提交 2a1d10b/781d8ea/11e306a + 工作区未提交 21 文件）
- 审查方式：只读，未改任何代码，未提交
- 规格来源：codex-checkpoint / FIX-F/G/H/K/V049M/线I 报告 / 任务规格 A-J + 键盘 K + 铁律
- 结论：总体忠实实现，新增文件均为真实现（无占位/假数据冒充）；发现 **3 个 critical（1 个编译必挂）**、1 个 high、若干 info

---

## Critical（功能缺失 / 假实现 / 编译阻断）

### C1. ChatView.swift 重复声明 `ChatMessageRow` → 编译必挂（最高优先）
- 位置：`ClawTalk/Features/Chat/ChatView.swift` 文件末尾两处完全相同声明（工作区约 L578 与 L608；`git show HEAD` 亦为 L584/L615，v049n 提交 2a1d10b 引入，两个修复提交未处理）
- 规格：线 E「消息气泡轻量化：ChatView 拆 ChatMessageRow 子视图」要求拆出**一份**子视图
- 实际偏差：同一文件内 `private struct ChatMessageRow: View { ... }` 被粘贴了两份（字节级确认 2 处 `private struct ChatMessageRow: View {`，body 完全一致）。Swift 顶层重复声明 = `invalid redeclaration of 'ChatMessageRow'`，**ClawTalk 主 target 编译必失败，整包无法出 IPA**
- 修复建议：删除其中一份（保留 L578 附近那份即可，两份内容相同）

### C2. ExpenseStore.swift:156 记账照片文件名双反斜杠 → 所有照片互相覆盖
- 位置：`ClawTalk/Features/Expense/ExpenseStore.swift:156`
  ```swift
  let name = "expense-\\(UUID().uuidString.prefix(8).lowercased()).jpg"
  ```
- 规格：线 G「每笔记账可附照片（文件落盘 + 列表缩略图 + 点击大图）」，要求每张照片唯一文件名
- 实际偏差：`\\(` 是转义反斜杠，字符串值恒为字面量 `expense-\(UUID().uuidString.prefix(8).lowercased()).jpg`，**不是插值**。所有照片保存为同一文件名 → 新照片覆盖旧照片；列表缩略图/大图全部指向同一张；`delete()` 联动删一张即删全部
- 修复建议：改为 `"expense-\(UUID().uuidString.prefix(8).lowercased()).jpg"`（去掉一个反斜杠）

### C3. 天气 API Key/城市设置链路：Key 会话内不生效、城市不落盘（半成品）
- 位置：`ClawTalk/Features/Settings/SettingsView.swift:102,509-511` / `ClawTalk/Features/Settings/SettingsStore.swift:31,57` / `ClawTalk/Features/DailyBriefing/DailyBriefingView.swift:184`
- 规格：线 I「天气：代码接天气 API + 设置填 Key 入口（Key 后填）→ 并入每日播报补齐」；FIX-LINE-I 报告自述「播报页下拉刷新即时生效」
- 实际偏差：
  1. `SettingsView` 的 Key `onChange` 只写钥匙串（`SecureStorage.setString`），**未赋值 `store.weatherAPIKey`**；`SettingsStore.weatherAPIKey` 仅在 `init()` 从钥匙串读一次。DailyBriefingEngine 用的是 Store 缓存 → **填 Key 后当次会话播报仍显示「天气未配置 API Key」（与事实不符，违背诚实提示），重启才生效**
  2. 城市 `TextField(text: $store.settings.weatherCity)` 只改内存 `@Observable`，**没有 `store.save()`** → 重启后回退默认「上海」
- 修复建议：`SettingsView.onChange` 同��� `store.weatherAPIKey = newValue`；城市字段走 `store.updateSettings { $0.weatherCity = newValue }` 或补 `onChange { store.save() }`

---

## High（功能偏�� / 半成品）

### H1. 提醒小组件数据不实时：`ClawTalkApp` 常驻 CareReminderStore 实例陈旧
- 位置：`ClawTalk/App/ClawTalkApp.swift:34`（`@State private var widgetReminderStore = CareReminderStore()`）+ `ClawTalk/Features/HomeCare/CareReminderStore.swift:127-137`（`load()` 私有、仅 init 调用）
- 规格：线 H「提醒 persist 发通知 + 3 秒同步循环 → WidgetCenter.reloadAllTimelines」实时刷新
- 实际偏差：`CareReminderStore` 非单例，页面各自 `CareReminderStore()`；`persist()` 只发 `dataDidChangeNotification`，不会让 App 内已存在的 `widgetReminderStore` 重载。`updateWidgetIfNeeded()` 读到的 `nextReminder` 是启动时的旧值 → **用户增删提醒后，小组件「下一条提醒」不更新（重启才刷新）**；3 秒循环兜底同样读到旧值
- 修复建议：收到通知时对 `widgetReminderStore` 调一次 reload（把 `load()` 提为 internal 或在通知回调里重建实例），或改为全局共享单例

---

## Info（细节偏差 / 建议）

### I1. ChatViewModel 分页加载含 250ms 人为延时（表演性加载）
- 位置：`ClawTalk/Features/Chat/ChatViewModel.swift` `loadEarlierMessages()`（`Task.sleep(250ms)`）
- 规格：线 E「滚动到顶『加载更早消息』（诚实加载态）」
- 偏差：数据本就在内存，仅窗口展开；250ms sleep 是专为「让加载中 UI 渲染出来」而加，属轻微表演性。不算造假但无必要
- 建议：窗口展开即时，可去掉 sleep（或保留但注明用途）

### I2. 主页卡片迁移与「清空主页卡片」冲突（边缘场景）
- 位置：`ClawTalk/Features/Home/HomeCardRegistry.swift` `migrateLineIFeaturesIfNeeded`
- 偏差：迁移基于一次性 UserDefaults 标记；若用户先「清空主页卡片」（storage=""）再触发迁移，4 张新卡（自动化/文件防丢/紧急求助/睡前陪伴）会被强制追加回主页，与清空意图冲突
- 建议：迁移仅在 `storage` 非空时执行，尊重用户清空

### I3. 线 F 底部录音区仍新建 `SettingsStore()`（预存量）
- 位置：`ClawTalk/Features/Habits/HabitsView.swift:133`、`ClawTalk/Features/HomeCare/ReminderListView.swift:152`
- 偏差：每次渲染 `GlobalVoiceInputEmbedded(settingsStore: SettingsStore())` 新建实例（钥匙串/App Group 同步 init 开销），且与页面注入的 store 不同步；Travel/KB/Expense 已用注入实例，风格不一致
- 建议：改用页面注入的 settingsStore

### I4. 格式类：缩进/空行不齐（不影响编译）
- 位置：`KBView.swift` 移除语音输入后残留空行；`TravelListView.swift`/`ExpenseListView.swift`/`HabitsView.swift` 的 `Divider()` 与 `bottomArea` 缩进层级不一致
- 建议：CI 前统一格式，避免后续合并冲突

### I5. 育儿功能未挂回主页（按规格待定处理，非遗漏）
- 规格「育儿功能挂回主页（挂法待明哥）」；本次新增 4 卡为自动化/文件防丢/紧急求助/睡前陪伴，育儿不在其中。符合「待明哥确认」状态
- Google Drive：本批 diff `--diff-filter=D` 为空（零删除）；主 App 已无 GD 代码，键盘包按约束未动

### I6. 线 A/C/D 已在基线，本次 diff 无对应新增
- 壁纸毛玻璃（SkinSettingsView/HomeWallpaper）、语音连接（voiceAgentSection/VoiceAgentGatewayProbe）、强制解包加固主体均在 2d05e1d 之前合入；本次 SecureStorage +12 为线 I 天气 Key 存储

### I7. VoiceAgentChannel 旧值迁移兜底过宽
- 位置：`ClawTalk/Models/AppSettings.swift` `init(from:)`
- 偏差：未知 rawValue 一律兜底 `.gateway`，异常数据被静默吞掉
- 建议：兜底前记一条日志（LogCollector），便于排查异常存档

### I8. 新增文件逐一核验结论（全部真实现，无占位/TODO 冒充/假数据）
- `WeatherService.swift`：OpenWeatherMap Current Weather 真请求（q/appid/lang=zh_cn/units=metric），失败抛错由引擎降级为诚实 skipNote ✓
- `GatewayCronClient.swift`：/cron/tasks、/cron/list 候选端点真探测（6s 超时、仅认 2xx+可解析 JSON 列表，防 HTML 404 误判），struct→final class 持状态 ✓；WS cron.list 仅提示未实现（规格即如此）✓
- `ExpenseXLSXExporter.swift`：OOXML 双表（明细+类别汇总）、inlineStr 转义、styles/rels/content_types、极简 ZIP（STORE+CRC32）均完整；FIX-G 已用 zipfile.testzip 验过 ✓
- `WidgetDataSync.swift`：App Group 键契约与 Widget 侧一致，记账/出行摘要读真实 UserDefaults，全空时返回空串（诚实空态）✓
- `ChineseNineGridIOSKeyboard.swift` / `LegacyChineseNineGridLayoutProvider.swift`：新样式独立类 + 旧布局提供器，互不引用，分发清晰 ✓
- `ClawTalkSwitchableWidget.swift`：AppIntentConfiguration + 7 卡真实渲染，无数据走诚实空态 ✓
- `ClawEnglishKeyboard`：v049m（85652d0）新增，早于基线 2d05e1d，不在本次 diff 范围

---

## 铁律检查

- 功能零删除：✓ `git diff 2d05e1d --diff-filter=D` 为空；无功能被删（Google Drive 已在更早批次处理）
- 键盘包强制解包不动：✓ 本批键盘包改动均为 K/L5 规格内改动（布局分发/候选栏/配色/Guru 改名迁移），无强制解包改动
- 诚实不造假：✓ 基本达标——OCR 解析不出如实弹手动补齐（带照片）、天气无 Key 如实跳过、记账空态/错误提示真实、小组件空态真实；例外：C3（天气 Key 缓存陈旧导致提示与事实不符）与 I1（250ms 表演性加载）

## 修复优先级建议

1. C1（编译阻断）→ C2（照片全灭）→ C3（天气设置不生效）→ H1（提醒小组件不刷新）
2. 其余 info 项可随下批一起处理
