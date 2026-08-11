# watchOS 手表端接线说明（ClawTalkWatchApp 骨架）

> 交付物：`ClawTalkWatchApp/`（watch app 容器 + watch 扩展代码）+ `project.yml` 两个新 target。
> 本文件是给主智能体（主 App 侧接线）的 TODO 清单。

## 1. 目标与结构

- `ClawTalkWatchApp`：watch2-app 容器（只含 Info.plist/Assets），embedded 进主 App（`Embed Watch Content`）。
- `ClawTalkWatchExtension`：watch2-extension，真正的 SwiftUI `@main` 与全部 watch 代码。
- 通信：手表不直连网关（网关 token 在 iPhone Keychain），全部走 WatchConnectivity 转发。
- 共享数据：App Group `group.7518554`（watch 扩展已加 entitlement），直接读主 App 每 3 秒写入的
  `channels_list` 频道列表。

## 2. 数据流

```text
watch 扩展 ──WCSession.sendMessage──▶ iPhone 主 App（WCSessionDelegate，待接线）
  sendText / wake / requestMessages / requestChannels

iPhone 主 App ──sendMessage/transferUserInfo──▶ watch 扩展（已实现接收）
  { kind: "messages", channelName, messages }
  { kind: "channels", channels }

语音输入：watch 端系统 dictation（无额外权限）→ sendText → iPhone 走网关 → 智能体
```

## 3. iPhone 主 App 侧 TODO（主智能体接线，勿动 watch 文件）

位置建议：`ClawTalk/App/AppDelegate.swift` 或 `ClawTalkApp.swift` 启动流程。

1. 持有并激活 `WCSession`：`WCSession.default.delegate = self; WCSession.default.activate()`。
2. 实现 `WCSessionDelegate`（iOS 侧必须实现 `activationDidCompleteWith`、
   `sessionDidBecomeInactive`、`sessionDidDeactivate`）与 `didReceiveMessage`（含 replyHandler 版）。
3. 处理 4 个 kind（payload 均为 `[String: Any]`）：
   - `sendText`：按 `channelName` 找频道（缺省用默认频道），聊天页开着走
     `ChatViewModel.sendText`，否则走网关 WebSocket/HTTP（复用 `ClawTalkApp.sendShareMessage`
     的链路）；回复 `{ "ok": Bool, "message": String? }`。
   - `wake`：触发与 `handleWakeWordDetected` 相同的「进入对话」流程；回复同上。
   - `requestMessages`：`ConversationStore.load(channelId:)` 最近 30 条，
     回复 `{ "kind": "messages", "channelName": "...", "messages": [WatchMessage JSON] }`。
   - `requestChannels`：回复 `{ "kind": "channels", "channels": [WatchChannel JSON] }`。
4. 主动推送：新消息落库/流式结束（`onRunFinished`）与频道变化时，向 watch
   发 `{ "kind": "messages", ... }` / `{ "kind": "channels", ... }`；
   iPhone App 运行中 `sendMessage`，否则 `transferUserInfo` 排队。
5. 编解码：`JSONEncoder`/`JSONDecoder` 默认策略；payload 只放 property-list 类型
   （String/Number/Bool/数组/字典），先 JSON 编码成 `[String: Any]` 再发，
   不要直接塞 `UUID`/`Data`/`Date`。

WatchMessage 字段：`id`(UUID 字符串)、`role`("user"/"assistant")、`content`、`timestamp`(Double)、`channelName`。
WatchChannel 字段：`id`、`name`、`agentId`(可选)。

## 4. 已依赖的共享代码

- `ClawTalkShared/` 只有 `LiveActivityAttributes.swift`（Live Activity 专用），watch 不依赖。
- 依赖的是 App Group 键 `channels_list`（`ClawTalkApp.syncChannelsToShare` 每 3 秒写入），
  以及 `WatchConnectivity` 消息契约（见 `WatchSessionManager.swift` 顶部注释）。

## 5. 遗留风险

- 签名：现有 `7517`/`7517ext` 描述文件若未勾选 watchOS 平台，watch 两个 target 无法真机签名。
  需在开发者后台为 `app.lgm.7517.watchapp` 与 `app.lgm.7517.watch` 补描述文件
  （或把 watchOS 设备加进现有 profile），`project.yml` 里暂用 `7517ext` 占位。
- `requestMessages` 需要 iPhone App 处于运行状态（`sendMessage` 可达）；App 被杀时手表只能
  看到 App Group 数据。后续可让主 App 把最近消息也写进 App Group（参照 widget 模式）。
- 图标：`Assets.xcassets/AppIcon.appiconset` 是空占位，上架前需补 watchOS 图标
  （1024x1024 单尺寸）与 complication 图标。
- 「提醒查看」：第一版靠 iPhone 推送镜像到手表（`PushManager` 已有），watch 侧本地通知/
  复杂功能（Complication）留作下一阶段。
- CI（`.github/workflows/build.yml`）跑 `xcodegen generate` 后只 build iOS scheme，
  新增 watch target 不影响现有构建；建议后续补一步 watch simulator build 的 CI job。