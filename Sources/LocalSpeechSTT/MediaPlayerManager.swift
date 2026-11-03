import Foundation
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class MediaPlayerManager: ObservableObject {
    @Published private(set) var isPlaying: Bool = false
    @Published var currentTime: Double = 0.0
    @Published var duration: Double = 0.0
    @Published private(set) var playbackRate: Float = 1.0

    private(set) var player: AVPlayer = AVPlayer()
    private var timeObserverToken: Any?
    private var endObserver: NSObjectProtocol?
    private var observations: [NSKeyValueObservation] = []
    /// While a seek is in flight, periodic time callbacks still report the old position; ignore them
    private var pendingSeekTarget: Double?

    init() {
        setupTimeObserver()
        setupStateObservers()
    }

    func load(url: URL, durationSeconds: Double) {
        player.pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.defaultRate = playbackRate
        duration = max(0, durationSeconds)
        currentTime = 0
        pendingSeekTarget = nil
        isPlaying = false

        if let endObserver = endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.duration
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
        player.defaultRate = playbackRate
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
        seek(to: 0)
    }

    func seek(to seconds: Double, autoPlay: Bool = false) {
        let upper = duration > 0 ? duration : max(0, seconds)
        let clamped = max(0, min(upper, seconds))
        let cmTime = CMTime(seconds: clamped, preferredTimescale: 600)
        pendingSeekTarget = clamped
        currentTime = clamped
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pendingSeekTarget == clamped else { return }
                self.pendingSeekTarget = nil
            }
        }
        if autoPlay {
            play()
        }
    }

    func setRate(_ rate: Float) {
        guard rate > 0 else { return }
        playbackRate = rate
        // `defaultRate` is used whenever playback is (re)started, including from AVPlayerView's own controls
        player.defaultRate = rate
        if isPlaying || player.rate != 0 {
            player.rate = rate
        }
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.08, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let secs = CMTimeGetSeconds(time)
            guard secs.isFinite else { return }
            Task { @MainActor in
                guard let self = self, self.pendingSeekTarget == nil else { return }
                self.currentTime = max(0, secs)
            }
        }
    }

    /// Keeps `isPlaying` / `playbackRate` in sync with the real player state, including changes made
    /// through the native video controls or by the system (end of item, audio route change, ...).
    private func setupStateObservers() {
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                let playing = status != .paused
                if self.isPlaying != playing {
                    self.isPlaying = playing
                }
            }
        })
        observations.append(player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor in
                guard let self, rate > 0, abs(rate - self.playbackRate) > 0.001 else { return }
                self.playbackRate = rate
            }
        })
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
