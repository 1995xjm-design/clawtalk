# FIX-H-WIDGET-20260814：线 H 小组件（记账快捷/拍照按钮/可切换卡片/实时刷新）

## 任务对照
1. 记账快捷小组件：今日/本月收支 + 点击打开记账页 —— 完成
2. 拍照按钮小组件：clawtalk://camera → App 打开记账页 —— 完成
3. 更多卡片：可切换卡片小组件（记账/拍照记账/提醒/健康/步数/出行/会话状态，编辑小组件切换）—— 完成
4. 实时刷新：记账/提醒数据变化 → 主 App 调 WidgetCenter.reloadAllTimelines() —— 完成

## 改动清单（11 个文件）
### 小组件扩展（ClawTalkWidget/）
| 文件 | 改动 |
| --- | --- |
| ClawTalkWidget/ClawTalkTimelineProvider.swift | 新增键 widget_expense_today / widget_expense_month / widget_health；条目新增 todayExpense/monthExpense/health 字段；新增 expenseURL（clawtalk://expense）与 cameraURL（clawtalk://camera） |
| ClawTalkWidget/ClawTalkFunctionWidgets.swift | 记账卡升级为「本月+今日」两行并挂 expenseURL；新增拍照记账卡（ClawTalkCameraWidget + ClawTalkCameraCardView，挂 cameraURL）；FunctionCardView 由 private 提为 internal 供可切换卡复用 |
| ClawTalkWidget/ClawTalkSwitchableWidget.swift（新增） | AppEnum 卡片选项 + WidgetConfigurationIntent（编辑小组件切换）+ AppIntentConfiguration 可切换卡片小组件（kind: ClawTalkSwitchable），7 种卡片各自挂对应深链 |
| ClawTalkWidget/ClawTalkWidgetBundle.swift | Bundle 注册 ClawTalkCameraWidget 与 ClawTalkSwitchableWidget |

### 主 App（ClawTalk/）
| 文件 | 改动 |
| --- | --- |
| ClawTalk/App/WidgetDataSync.swift（新增） | 小组件数据写入唯一入口：键常量、write()（写 App Group + WidgetCenter.reloadAllTimelines）、记账今日/本月摘要（真实 UserDefaults 数据）、停车摘要、健康/步数摘要；dataDidChangeNotification 通知名 |
| ClawTalk/App/ClawTalkApp.swift | WidgetSnapshot 扩展（今日/本月收支、提醒、出行）；updateWidgetIfNeeded 全键写入 + reload；新增记账页 sheet（小组件深链落地）；handleIncomingURL 新增 expense/camera 分支（切主页 + 打开记账页）；观察 dataDidChangeNotification 立即刷新 |
| ClawTalk/DeepLink/DeepLinkHandler.swift | Action 新增 expense / camera / home，handle 返回已识别（跳转由 ClawTalkApp 负责） |
| ClawTalk/Features/Expense/ExpenseStore.swift | persist() 增发记账数据变化通知（线 G 的拍照/照片改动保留，已合并） |
| ClawTalk/Features/HomeCare/CareReminderStore.swift | persist() 增发提醒数据变化通知 |
| ClawTalk/Features/HomeCare/HealthViewModel.swift | 健康页加载成功（已授权）后写步数/健康摘要到小组件键 |
| project.yml | ClawTalkWidget target 增加依赖 - sdk: AppIntents.framework（AppIntentConfiguration 需要） |

## 数据流
- 记账/提醒/出行数据：主 App 3 秒同步循环（runWidgetAndShareSyncLoop）比对 WidgetSnapshot，变化才写入 App Group 并 reloadAllTimelines
- 记账（ExpenseStore.persist）/ 提醒（CareReminderStore.persist）变化：额外发通知 → ClawTalkApp 立即 updateWidgetIfNeeded（即时刷新，3 秒循环兜底）
- 健康/步数：HealthViewModel 授权成功后写 widget_steps / widget_health；未授权保持诚实空态
- 小组件点击：clawtalk://expense / clawtalk://camera → 主 App 打开记账页；clawtalk://home 只开 App；clawtalk://open?channel= 原有会话直达不变

## 自查结果
- 全部改动文件 UTF-8 无 BOM，FFFD=0
- 括号配对：10 个 Swift 文件大括号/圆括号/方括号全部配对（ClawTalkApp 圆括号 424/425 为 HEAD 既有，非本次引入）
- 键契约一致性：widget 侧 11 个键与主 App 侧 WidgetDataSync 全部一一对应
- 深链映射：小组件 expenseURL/cameraURL ↔ ClawTalkApp handleIncomingURL 分支一致
- 功能零删除：原 6 个小组件全部保留，主 App 会话/深链/分享逻辑未删改
- git status：本次改动文件均在白名单（ClawTalkWidget/* + 主 App 数据共享相关）；其余未提交改动为并行批次/既有脏文件，未触碰

## 风险与说明
- 无 Xcode 环境，未本地编译；编译由 CI（macos-15 + xcodegen + xcodebuild）验证。AppIntentConfiguration 需 iOS 17+（项目 deploymentTarget 17.0，满足）
- 并行线 G 正在改 ExpenseStore/ExpenseListView：ExpenseStore 本次改动已与线 G 内容合并共存；若线 G 后续整文件覆盖，需主智能体合并时保留 persist() 的通知行
- ExpenseListView init(settingsStore:store:onBack:) 参数均有默认值，ClawTalkApp 调用兼容
- 健康/步数卡片数据依赖 HealthKit 授权（用户打开过健康卡才写入），未授权显示诚实空态，不造假
- 拍照记账具体拍照/OCR 交互在线 G（记账报表）实现；本线深链先落记账页，线 G 合并后即达拍照入口

## SHA256
| 文件 | SHA256 |
| --- | --- |
| ClawTalk/App/WidgetDataSync.swift | B2608E51EE8563AF2ACF1C9C58467B5CBD5147BF5FE88CE01AB5DF54ED0FD896 |
| ClawTalk/App/ClawTalkApp.swift | 2D9928348BE9C773A1B00701E7526902E583E97B5A3ED7211A9BD0F3BFFE117C |
| ClawTalk/DeepLink/DeepLinkHandler.swift | 295B2C4B3962CD8405737FF094BC2EB8D1A9D7D1402ED3B00A68B17A30C98660 |
| ClawTalk/Features/Expense/ExpenseStore.swift | 427E7D5D5DD559F4156BB29ADC396AF22629AEB64BDAF909F9EF940446D310A2 |
| ClawTalk/Features/HomeCare/CareReminderStore.swift | 947CACBD606B6269D1B7611DA44F8009663533A88B10E485C78C08FB529B3715 |
| ClawTalk/Features/HomeCare/HealthViewModel.swift | D9F5B43E0E67E4218FF7CF8491D418D448D27AB17DFDFCFF98792AC248F3289D |
| ClawTalkWidget/ClawTalkTimelineProvider.swift | 11ED14D553E18633508D2A074335065DED298873EC58AE6B2189FE1EF9FA11E9 |
| ClawTalkWidget/ClawTalkFunctionWidgets.swift | EC63AF2A12CDA530C5D920930A0FB1E9EB495D3799F135288568E1DE2B243B0D |
| ClawTalkWidget/ClawTalkSwitchableWidget.swift | 908305F3FD968A30E96211526A9439F1DD9FD2F4A10D061B950BD545395ED3D1 |
| ClawTalkWidget/ClawTalkWidgetBundle.swift | 622C56C81D7C2648BA5FAC7DBF05B4E11FA757A883DDD1B24B7DE3800EECF2AB |
| project.yml | FA69B18416CE1288672D8A9455A84A6FA38AB3BA69AD4F553DB1B8A03F243013 |

## 部署步骤（小强）
1. CI（push main 或 workflow_dispatch）跑 xcodegen generate + 4 target 编译，确认 build-widget.log 通过
2. 打包签名后真机验证：添加「ClawTalk 记账」「ClawTalk 拍照记账」「ClawTalk 卡片」小组件
3. 记账页记一笔 → 返回桌面看小组件今日/本月数字更新（即时刷新验证）
4. 长按「ClawTalk 卡片」→ 编辑小组件 → 切换卡片类型
5. 点击小组件 → App 打开记账页