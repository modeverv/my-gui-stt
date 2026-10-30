import Foundation
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class MediaPlayerManager: ObservableObject {
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published var playbackRate: Float = 1.0

    private(set) var player: AVPlayer = AVPlayer()
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?

    init() {
        setupTimeObserver()
    }

    func load(url: URL, durationSeconds: Double) {
        stop()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        duration = max(0, durationSeconds)
        currentTime = 0

        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
            }
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard player.currentItem != nil else { return }
        if duration > 0 && currentTime >= duration - 0.1 {
            seek(to: 0)
        }
        player.playImmediately(atRate: playbackRate)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func stop() {
        player.pause()
        isPlaying = false
        currentTime = 0
    }

    func seek(to seconds: Double, autoPlay: Bool = false) {
        let clamped = max(0, min(duration > 0 ? duration : seconds, seconds))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        if autoPlay {
            play()
        }
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying {
            player.rate = rate
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let secs = CMTimeGetSeconds(time)
            guard secs.isFinite else { return }
            Task { @MainActor in
                guard let self = self else { return }
                self.currentTime = max(0, secs)
                if self.player.timeControlStatus == .paused && self.isPlaying {
                    self.isPlaying = false
                }
            }
        }
    }
}

/// Native AppKit AVPlayerView wrapper for clean video preview on macOS.
struct NativeVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
