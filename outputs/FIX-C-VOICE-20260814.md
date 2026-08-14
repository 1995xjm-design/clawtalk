# FIX-C 语音朗读/唤醒词添加/日志诊断鉴权（子智能体 C 批次 2026-08-14）

## 改动清单（仅白名单 5 文件）
1. ClawTalk/Core/TTS/AppleTTSService.swift —— 长文朗读分段续接
   - 根因：整段文本做成单个 AVSpeechUtterance，超长朗读被系统中途静默截断；分段场景无续接逻辑。
   - 修复：按句末标点（。！？；…换行等）+ 180 字符兜底分段，逐段顺序朗读；didFinish / didCancel 均续读下一段，全部读完才结束流；用户主动 stop 仍立即停止（stopped 门控），不影响打断。
2. ClawTalk/Features/VoiceAssistant/VoiceAssistantViewModel.swift —— 打断朗读感知
   - 根因：打断（handleInterrupt）后旧朗读任务的播放等待可能空转；且旧任务收尾 audioPlayback.stop() 会误杀打断后新一轮对讲刚启动的播放引擎（新输入朗读无声）。
   - 修复：Task 取消后跳过播放等待并立即返回；仅未取消时收尾 stop()，避免误杀新轮播放；speak 返回值语义不变。
3. ClawTalk/Core/Node/VoiceWakeCapability.swift —— 唤醒词规范化
   - 根因：normalizedKeywords 定义了却从未被调用，编辑/粘贴带空白的词永远无法命中（添加后不生效）。
   - 修复：setConfig 统一走 normalizedKeywords（去空白/去空词/去重），空词判断改用规范化结果。
4. ClawTalk/Features/Settings/VoiceSettingsView.swift —— 添加唤醒词 UI
   - 根因：添加词用 .alert+TextField，与「语音预览失败」alert 叠在同一视图（SwiftUI 同视图多 alert 只生效最后一个），且 alert 内 TextField 对中文输入法不友好，导致添加失败/无效。
   - 修复：改为 .sheet 表单输入（中文输入法可靠）；「添加」空词禁用；addWakeWord 去重+去空白；落盘前清洗词表；热更新失败记日志；引擎未监听时依赖看门狗按新词表重启。
5. ClawTalk/Features/Settings/DiagnosticsView.swift —— 日志诊断鉴权适配网关令牌
   - 根因：同步到 OpenClaw 直接传 settings.gatewayToken（二维码配对场景为空 → 误报 401「鉴权未适配网关令牌」）；HTTP 鉴权探测走 /health（可能未鉴权 200 假通过，且未用 TLS 放行会话）。
   - 修复：同步/鉴权统一用 OpenClawClient.resolveHTTPToken（优先配对 device token，回退手填令牌）；鉴权探测先走带令牌的 /v1/models（与 App 实际请求一致），网关无该接口（404）时回退 /health；改用 TLS 指纹放行会话，自签证书（已加信任）不误报。

## 自查结果
- 5 文件均为 UTF-8 无 BOM、FFFD 计数 = 0、括号配对 OK；末尾换行与原文保持一致。
- 未改动语音大卡状态机 / VAD / 发送链路（handleUtterance / startConversation / requestAgentReply / handleInterrupt 均未动），speak 返回语义不变，不破坏语音大卡对话主流程。
- git status：本次仅上述白名单 5 文件；仓库内其余已修改文件为并行子代理（16:16 前）的改动，未触碰。
- Windows 无 Xcode，未本地编译；改动按 Swift 6 / iOS 16+ API 静态核对，编译由 CI build.yml 验证。

## SHA256
- ClawTalk\Core\TTS\AppleTTSService.swift  SHA256: da8fb1e097392694ee2bee1bc5f920ccbb454195c87a523e9edc918e64bad6ed
- ClawTalk\Features\VoiceAssistant\VoiceAssistantViewModel.swift  SHA256: c40886110978117cab35b13e7b504121c7ca798526e255e5fa9037fa3573002a
- ClawTalk\Core\Node\VoiceWakeCapability.swift  SHA256: b3f6b47119914dc69f2d8e80caa8686e6fa94191ebf4ac0b16bd300e9c56f406
- ClawTalk\Features\Settings\VoiceSettingsView.swift  SHA256: f7df139b6342f6a0d7daf93d9d688f748f7c8ec39deba36ed8b3cd0029882e05
- ClawTalk\Features\Settings\DiagnosticsView.swift  SHA256: 7966283f5210934efed287a4b6701f8ad32428c109bbbafd761ea38d2fe7fbc1

## 风险
- AppleTTS 分段后句末自然停顿/语速与整段略有差异（预期内）。
- /v1/models 探测遇网关限流（429）会如实报「网关返回 HTTP 429」，非误报。
- 与并行子代理改动同仓共存，需 CI 整包编译 + 真机回归（长文朗读、唤醒词添加/命中、日志诊断一键诊断）后交付。