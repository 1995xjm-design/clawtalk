import SwiftUI

struct ModelDownloadView: View {
    let modelSize: WhisperModelSize
    let onComplete: () -> Void
    let onSkip: () -> Void

    @State private var manager = WhisperModelManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 56))
                .foregroundStyle(.openClawRed)

            Text("语音设置")
                .font(.title2)
                .fontWeight(.bold)

            Text("ClawTalk 使用设备端语音模型进行本地语音转文字，音频不会离开你的手机。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 8) {
                Text(modelSize.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if manager.isDownloading {
                    ProgressView(value: manager.downloadProgress)
                        .tint(.openClawRed)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                    Text("下载中... \(Int(manager.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = manager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .padding(.top, 8)

            Spacer()

            VStack(spacing: 12) {
                if manager.isDownloading {
                    // 下载中可先进 App，下载任务不取消、完成后语音自动可用
                    Button("先进 App") {
                        onSkip()
                    }
                    .foregroundStyle(.secondary)

                    Text("模型下载中，可先进入 App，下载完成后语音自动可用。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                } else if manager.errorMessage != nil {
                    Button(action: {
                        Task {
                            await manager.downloadModel(size: modelSize)
                            if manager.isModelReady {
                                onComplete()
                            }
                        }
                    }) {
                        Text("重试下载")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.openClawRed)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 24)

                    Button("稍后再说") {
                        onSkip()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else {
                    Button(action: {
                        Task {
                            await manager.downloadModel(size: modelSize)
                            if manager.isModelReady {
                                onComplete()
                            }
                        }
                    }) {
                        Text("下载语音模型")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.openClawRed)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 24)

                    Button("稍后再说") {
                        onSkip()
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground))
    }
}