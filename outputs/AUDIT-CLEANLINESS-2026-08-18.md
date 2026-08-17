# AUDIT-CLEANLINESS 代码干净度检测报告（2026-08-18）

> 基线：HEAD 9a44d9c（v083，build 26，CI success）
> 检测范围：全仓库 git 跟踪文件（754 Swift + 资源 + 脚本），重点 ClawTalk / ClawTalkShared / 各扩展 target。

## 结论
总体干净：无重复 Swift 文件、无同名类型冲突、无空依赖、无假数据进主功能、IPA 资源无冗余平铺。
发现 5 类问题，其中 1 个是真 Bug（用户可见文案损坏），1 个是明哥已下令删除的三端同步遗留。

## 🔴 问题清单（按严重度）

### P0-1 用户可见连接错误文案全部损坏（真 Bug）
- 位置：`ClawTalk/Core/Gateway/GatewayWebSocket.swift` 783-800 行
- 内容：AUTH_*/DEVICE_AUTH_* 错误码 → `.connectFailed("??????????")`，8 处
- 影响：扫码/连接失败时用户看到一串问号（Release 生效）
- 根因：v071（b9de8f5）新增错误码映射时写入即损坏，git 历史无原文，需重写中文
- 建议：按错误码语义重写 8 条文案（令牌无效/设备令牌不匹配/签名校验失败/签名过期/权限范围不匹配/密码错误/频率限制/Tailscale 身份校验）

### P0-2 三端同步遗留 server/（明哥已下令删除的功能）
- 位置：`server/`（7 个跟踪文件：claude-bridge-server.js、bridge/server.js、CLAUDE-BRIDGE-GUIDE.md 等）
- 内容：「把 Claude 接入 ClawTalk」桥接 Node 服务器 + 指南（2026-08-10 创建）
- 影响：Swift 端 CODEX/CLAUDE 同步已删净，此目录零引用（CI/脚本/Swift 均无），纯死代码
- 建议：整目录删除（git rm -r server）

### P1-3 注释/文案乱码残留（26 处 ? 串 + 2 处 U+FFFD）
- `ClawTalkApp.swift` 208/487、`GatewayConnection.swift` 23/493/524/540/543/548/554/562/570、
  `GatewayWebSocket.swift` 778、`NodeConnection.swift` 295/296、`TTSError.swift` 3、
  `ChannelListView.swift` 191、`ChatView.swift` 420、`SettingsView.swift` 64 —— 18 处注释 ? 串
- `ClawTalkWatchApp/Extension/MessageListView.swift:5` —— 1 处 U+FFFD
- `project.yml:93` —— 1 处乱码注释（18789/18890 HTTP 说明）
- 影响：不影响功能，但代码不干净，新人读代码像天书
- 建议：按上下文恢复中文注释

### P2-4 未使用资源（可减仓）
- `ClawTalk/Resources/Assets.xcassets/Logo.imageset` + `LogoWhite.imageset`：代码零引用（仅 LogoRed 在用），其中 Logo.png 与 `assets/app-icon.png` 完全重复
- `assets/store-screenshots/06-settings-voice-alt.png` 与 `06-settings-voice.png` 内容重复
- 建议：删 Logo/LogoWhite imageset；去重 alt 截图

### P2-5 Debug 假数据种子（Claude 品牌演示残留）
- 位置：`ClawTalk/Debug/DemoDataSeeder.swift`（17KB）+ `ClawTalkApp.swift:44` 调用
- 内容：DEBUG 构建下自动种入 Claude Sonnet 品牌演示对话（三端同步时代残留）
- 影响：`#if DEBUG` 包住，Release IPA 不含；但违反「不塞假数据」精神，Debug 跑起来会看到假对话
- 建议：删除文件 + 删除启动调用（Release 无影响，Debug 变干净空状态）

## ✅ 已验证干净的部分
- 无重复 Swift 文件：内容哈希重复全部在 KeyboardPackages（官方源+产物）与键盘双份 Rime（设计必需，主 App 1 份 + appex 1 份）
- 无同名类型冲突：重复的 AppSettings/ConnectionState/Item/Outcome/Snapshot 等均为私有局部类型（正常 Swift 写法）
- project.yml 全部 target/依赖实际使用：KeychainAccess/MarkdownUI/HamsterKit/UIKit/iOS/KeyboardKit/RimeKit 均被引用，无空包
- Frameworks/（librime 等 5 个 xcframework 24.8MB）为键盘必需，CI 有兜底下载
- assets/（截图 5.1MB）不入 IPA，仅 App Store 素材
- 无假数据进主功能：全部为空状态诚实处理（VoiceDiary/Dictation/Expense/Home/Meeting/Writing 等）
- git status 干净，无未提交改动
- B8 键盘设置直达已实现（SettingsView.swift:1180-1197），无「框中框」残留

## 建议��置（一次批量）
1. 重写 GatewayWebSocket 8 条中文错误文案（P0）
2. git rm -r server（P0）
3. 恢复 19 处乱码注释 + project.yml 注释（P1）
4. 删 Logo/LogoWhite imageset + alt 截图去重（P2）
5. 删 DemoDataSeeder + 启动调用（P2）
预计影响：Release IPA 体积不变（无资源增减），代码干净度显著提升；改动均为低风险，重写文案后 CI 验证一次。
