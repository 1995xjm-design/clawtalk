import Foundation

/// 语音消息附件：录音文件保存在本地，通过 id 与 Message 关联。
///
/// 诚实标注：OpenClaw 网关是否支持语音附件（audio 类型）未确认，默认 `sentAsText = true`，
/// 消息以「录音 → STT 转文字 → 发文字」降级发送，本地文件仅用于气泡内回放；
/// 主智能体确认网关支持后启用 `ChatViewModel.voiceAttachmentTransportSupported` 走附件上传。
struct VoiceMessageAttachment: Identifiable, Sendable {
    /// 附件唯一标识（与 Message.id 一致，供气泡查找）。
    let id: UUID
    /// 本地音频文件（WAV 16kHz 16bit 单声道，AVAudioPlayer 可直接播放）。
    let localFileURL: URL
    /// 录音时长（秒）。
    let duration: TimeInterval
    /// STT 转写文本（非空即说明走了文字链路）。
    let transcript: String
    /// 是否已降级为「文字发送」：true = 网关未确认支持语音附件（当前默认）。
    var sentAsText: Bool
}
