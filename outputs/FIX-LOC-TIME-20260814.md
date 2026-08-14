# FIX-LOC-TIME-20260814 — ClawTalk 修复批次子智能体 A 交付报告

- 日期：2026-08-14
- 角色：ClawTalk 修复批次子智能体 A（只改白名单，未提交未推送）
- 仓库：fusion/ClawTalk（工作区直接修改）

## 一、改动清单

### 1. LocationCapability.swift（Core/Node）
- LocationError.timeout 文案由「定位请求超时」改为「定位超时，请到开阔处重试」。
- waitForAuthorization() 增加 15 秒超时兜底：到点抛 .timeout，不再无限转圈。
- waitForLocation() 增加 15 秒超时兜底：到点抛 .timeout，不再无限转圈。
- 新增 NSLock 保护的一次性恢复（先取走 continuation 并置 nil 再 resume），
  避免「超时任务」与「定位回调」竞态导致重复 resume 崩溃；正常定位路径（授权成功→拿到坐标）不受影响。

### 2. GeofenceListView.swift（Features/Geofence）
- 围栏表单「使用当前位置」错误显示沿用已有 locationError；
  etchCurrentLocation() 增加 catch let error as LocationCapability.LocationError 分支，
  已知定位错误（拒绝 / 不可用 / 超时）直接展示友好文案，超时即显示「定位超时，请到开阔处重试」。

### 3. ParkingView.swift（Features/Parking）
- ecordCurrentLocation() 在 .notDetermined 请求授权后，新增授权监听：
  授权成功自动调用 startLocationCapture()（用户不用再点一次「记录」）；
  授权被拒则自动弹出设置引导（诚实提示）。
- 新增 ParkingAuthorizationWatcher（NSObject + CLLocationManagerDelegate）：
  监听 locationManagerDidChangeAuthorization，start() 同步兜底当前状态。
- ParkingLocationFetcher 超时由 15 秒放宽到 20 秒（注释同步更新）。

### 4. 聊天时间统一（主聊天页 + SyncChatView）
- 新增共享格式化助手 ChatBubbleTimeText（定义在 MessageBubble.swift，同模块可见）：
  今天只显示时分（HH:mm），非今天显示「MM-dd HH:mm」。
- MessageBubble.swift：消息气泡时间改用统一格式（原 ormatted(date:time:)）。
- VoiceMessageBubble.swift：语音气泡时间改用统一格式（原 style: .time）。
- SyncChatView.swift：SyncBubble 与 SyncSearchView 两处时间统一格式。
- ChatSearchView.swift：主聊天页搜索结果显示时间统一格式。

## 二、自查结果

- 7 个白名单文件全部：UTF-8 无 BOM、FFFD=0、括号配对通过
  （MessageBubble 中正则原样字符串 #"!\[[^\]]*..."# 的方括号差为 HEAD 原有，非本次引入）。
- 文件末尾均补齐换行，格式正常。
- 未提交、未推送；git 仅含白名单文件的本次改动。

## 三、并发改动说明（重要）

工作区为共享目录，本次会话期间检测到其他智能体的并发改动（非本子代理操作）：
- ClawTalk/Features/Tools/FileTransferView.swift（16:13 修改，多文件上传结果列表 UI）
- ClawTalk/Features/Sync/SyncChatView.swift 中「已选图片预览」块（16:15 修改）
以上改动被完整保留，未覆盖未回退；请主智能体合并时留意。

## 四、风险与注意事项

- LocationCapability 超时任务持有 delegate 至多 15 秒，回调后自动置 nil，无泄漏。
- ParkingAuthorizationWatcher 在用户一直不响应授权弹窗时会被保留至视图销毁
  （轻量对象，无网络/定位持续请求，风险低）。
- 定位超时兜底是 UI 层友好提示；系统定位本身无网络时仍以系统回调为准。
- 聊天时间格式为「今天 HH:mm / 非今天 MM-dd HH:mm」，如需「yyyy/MM/dd HH:mm」可一行调整 ChatBubbleTimeText。

## 五、SHA256（7 个改动文件）

- LocationCapability.swift: 6B59E7B95FB5E70ED1F4A6B1FC4BFC71CD8B2ABA9A984D92B5AD68391CF4AB6E
- GeofenceListView.swift: 99A98DD087E7DF3FD0903817FD0D5751812E8AF40413998F9BDC10332C20F76B
- ParkingView.swift: F1EF7677B94400D1FF12D4FF23118822748C8BAFE2D1C2CA1C2F347D9F6DC1FA
- MessageBubble.swift: 8DF51B301E14ABE275AAC8C2B62F58644C8FE2F20B9D90342C11E00E97A1CDA0
- ChatSearchView.swift: 88310C6005A25CCF2E7CC3B2071648BC6D32B5594B0C58136C549697BAF7612B
- VoiceMessageBubble.swift: 4219ED983C5A2C02DD19FA3B7B1F3A585AE24DE5B29E48B02866C750682A6E0C
- SyncChatView.swift: 580759C01B4DC94AF754A86942FCE1483A3C70DB370EB8C0EBA3847842A903A0

## 六、部署 / 验证建议（小强）

- 由 CI 编译验证（Windows 本机无 Xcode，未做本机编译）。
- 真机验证路径：
  1. 围栏表单「使用当前位置」→ 拒绝/忽略弹窗 15 秒 → 应显示「定位超时，请到开阔处重试」。
  2. 停车页首次点「记录」→ 允许授权 → 应自动开始定位并记录（无需二次点击）。
  3. 聊天页发送/接收消息 → 今天消息只显示时分；历史（非今天）消息显示「MM-dd HH:mm」；
     SyncChatView 同步消息一致。