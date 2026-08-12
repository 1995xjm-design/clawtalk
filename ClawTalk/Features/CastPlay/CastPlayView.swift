import SwiftUI

/// 投屏播放控制页（F2）：
/// - 投屏：系统 AVRoutePickerView（AirPlay 面板）
/// - 控制：系统正在播放的播放/暂停 + 当前曲目
/// - 诚实标注能力范围（iOS 限制第三方 App 控制他 App 播放）
struct CastPlayView: View {
    @State private var viewModel = CastPlayViewModel()
    var onBack: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            navBar
            Divider().opacity(0.3)
            ScrollView {
                VStack(spacing: 16) {
                    castCard
                    controlCard
                    honestNote
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
        }
        .onAppear { viewModel.refresh() }
    }

    // MARK: - 导航栏

    private var navBar: some View {
        ZStack {
            Text("投屏播放")
                .font(.headline)
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(10)
                            .background(Color(.systemGray5), in: Circle())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 52)
    }

    // MARK: - 投屏入口

    private var castCard: some View {
        VStack(spacing: 12) {
            RoutePickerButton(tintColor: .white)
                .frame(width: 68, height: 68)
                .background(Color.openClawRed, in: Circle())
                .shadow(color: Color.openClawRed.opacity(0.35), radius: 8, y: 3)
            Text("投屏到电视 / 音响")
                .font(.subheadline.weight(.medium))
            Text("点按弹出系统投屏面板，选择隔空播放设备")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 播放控制

    private var controlCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("系统正在播放")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(viewModel.mediaAuthorizationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                Text(viewModel.nowPlayingTitle ?? "暂无正在播放的曲目")
                    .font(.headline)
                    .lineLimit(1)
                if let artist = viewModel.nowPlayingArtist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            Button(action: viewModel.togglePlayPause) {
                ZStack {
                    Circle()
                        .fill(viewModel.isPlaying ? Color.openClawRed : Color(.systemGray4))
                        .frame(width: 72, height: 72)
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .accessibilityLabel(viewModel.isPlaying ? "暂停" : "播放")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 诚实能力说明

    private var honestNote: some View {
        Label(
            "受 iOS 限制，本页只能控制「系统正在播放」（Apple Music 等）。其他 App 的播放请用投屏面板切换设备接管。",
            systemImage: "info.circle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
