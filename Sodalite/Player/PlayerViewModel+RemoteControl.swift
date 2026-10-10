import AetherEngine
import Foundation

/// Commands from another Jellyfin client. Each one reports progress straight away, so the remote
/// that sent it sees the new state on its next poll rather than at the next periodic report.
extension PlayerViewModel: RemotePlaybackSurface {
    func remotePause() {
        guard isPlaying else { return }
        togglePlayPause()
    }

    func remoteUnpause() {
        guard !isPlaying else { return }
        togglePlayPause()
    }

    func remoteTogglePlayPause() {
        togglePlayPause()
    }

    func remoteSeek(toSeconds seconds: Double) {
        guard !isLiveSession else { return }
        Task { [weak self] in
            await self?.player.seek(to: max(seconds, 0))
            self?.reportProgressIfNeeded()
            self?.showControlsTemporarily()
        }
    }

    func remoteNextTrack() {
        guard nextEpisode != nil else { return }
        Task { [weak self] in await self?.playNextEpisode() }
    }

    /// The player has no history to go back through, so previous restarts the item, as a remote's
    /// back button does on a single item.
    func remotePreviousTrack() {
        remoteSeek(toSeconds: 0)
    }
}
