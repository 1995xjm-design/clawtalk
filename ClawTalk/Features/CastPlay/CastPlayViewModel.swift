import Foundation
import MediaPlayer

/// 投屏播放控制 ViewModel（F2）：
/// 控制系统「正在播放」（MPMusicPlayerController.systemMusicPlayer）。
/// 诚实能力范围：iOS 不允许第三方 App 控制其他 App 的播放队列，
/// 这里只能控制系统级正在播放（Apple Music 等）；其余 App 请用系统投屏面板接管。
@Observable
@MainActor
final class CastPlayViewModel {
    private let player = MPMusicPlayerController.systemMusicPlayer

    private(set) var isPlaying = false
    private(set) var nowPlayingTitle: String?
    private(set) var nowPlayingArtist: String?

    /// 媒体库授权状态：仅用于提示文案，控制/读取「正在播放」不受此限制。
    var mediaAuthorizationText: String {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: return "已授权媒体库"
        case .denied, .restricted: return "媒体库未授权（不影响系统播放控制，仅影响历史/资料读取）"
        case .notDetermined: return "尚未请求媒体库权限"
        @unknown default: return "媒体库权限未知"
        }
    }

    func refresh() {
        isPlaying = player.playbackState == .playing
        nowPlayingTitle = player.nowPlayingItem?.title
        nowPlayingArtist = player.nowPlayingItem?.artist
    }

    func togglePlayPause() {
        if player.playbackState == .playing {
            player.pause()
        } else {
            player.play()
        }
        refresh()
    }
}
