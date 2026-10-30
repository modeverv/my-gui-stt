import SwiftUI
import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURLs: (([URL]) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        onOpenURLs?(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct LocalSpeechSTTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    init() {
        let args = CommandLine.arguments

        // Support "--capture-screenshot <out.png> [audio_file]" to render a native window screenshot
        if let shotIdx = args.firstIndex(of: "--capture-screenshot"), shotIdx + 1 < args.count {
            let outPath = args[shotIdx + 1]
            let mediaPath = (shotIdx + 2 < args.count) ? args[shotIdx + 2] : nil
            ScreenshotCaptureRunner.runAndExit(outputPath: outPath, mediaPath: mediaPath)
        }

        // Support "--cli <filepath> [--max-seconds <N>]" for automated verification & batch processing
        if let cliIdx = args.firstIndex(of: "--cli"), cliIdx + 1 < args.count {
            let filePath = args[cliIdx + 1]
            var maxSeconds: Double? = nil
            if let maxIdx = args.firstIndex(of: "--max-seconds"), maxIdx + 1 < args.count {
                maxSeconds = Double(args[maxIdx + 1])
            }
            CLIVerificationRunner.runAndExit(filePath: filePath, maxSeconds: maxSeconds)
        }
    }

    var body: some Scene {
        WindowGroup("LocalSpeechSTT — ローカル音声・動画文字起こし (Apple Speech)") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 960, idealWidth: 1120, minHeight: 660, idealHeight: 760)
                .onAppear {
                    appDelegate.onOpenURLs = { urls in
                        if let first = urls.first {
                            Task { @MainActor in
                                await viewModel.loadMediaFile(url: first)
                            }
                        }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("動画・音声ファイルを開く...") {
                    viewModel.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("文字起こし") {
                Button(viewModel.isTranscribing ? "文字起こしを停止" : "文字起こし開始") {
                    if viewModel.isTranscribing {
                        viewModel.cancelTranscription()
                    } else {
                        viewModel.startTranscription()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.mediaInfo == nil)

                Divider()

                Button("結果をクリップボードにコピー") {
                    viewModel.copyTranscriptToClipboard()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(viewModel.segments.isEmpty)

                Button("テキスト (.txt) として保存...") {
                    viewModel.exportTranscriptToFile(format: .txt)
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(viewModel.segments.isEmpty)

                Button("SRT字幕 (.srt) として保存...") {
                    viewModel.exportTranscriptToFile(format: .srt)
                }
                .disabled(viewModel.segments.isEmpty)
            }
        }
    }
}

// MARK: - CLI Verification / Headless Test Runner

enum CLIVerificationRunner {
    static func runAndExit(filePath: String, maxSeconds: Double?) -> Never {
        Task {
            do {
                let inputURL = URL(fileURLWithPath: filePath)
                let info = try await MediaInspector.inspect(url: inputURL)
                print("=== Media Inspection ===")
                print("File: \(info.fileName) (\(info.formattedFileSize))")
                print("Duration: \(info.formattedDuration) (\(String(format: "%.1f", info.durationSeconds))s)")
                print("Format: \(info.formatSummary)")

                var targetURL = inputURL
                var tempClipURL: URL? = nil
                defer {
                    if let tmp = tempClipURL {
                        try? FileManager.default.removeItem(at: tmp)
                    }
                }

                if let maxSec = maxSeconds, maxSec > 0 && maxSec < info.durationSeconds {
                    print("Creating \(Int(maxSec))s test slice for fast verification...")
                    let reader = try await MediaInspector.prepareAudioReader(for: inputURL)
                    if let slice = reader.readMonoSamples(startTime: 0, endTime: maxSec, maxDuration: maxSec + 1.0),
                       let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(slice.sampleRate), channels: 1, interleaved: false),
                       let pcmBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(slice.samples.count)),
                       let ch0 = pcmBuf.floatChannelData?[0] {
                        pcmBuf.frameLength = AVAudioFrameCount(slice.samples.count)
                        _ = slice.samples.withUnsafeBufferPointer { src in
                            memcpy(ch0, src.baseAddress!, slice.samples.count * MemoryLayout<Float>.size)
                        }
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("verify_clip_\(UUID().uuidString).wav")
                        do {
                            let outFile = try AVAudioFile(forWriting: tmp, settings: fmt.settings)
                            try outFile.write(from: pcmBuf)
                        }
                        targetURL = tmp
                        tempClipURL = tmp
                    }
                }

                let config = TranscriptionConfig(
                    engine: .speechTranscriber,
                    localeIdentifier: "ja_JP",
                    speakerMode: .auto,
                    pauseThresholdSeconds: 0.45,
                    maxSegmentDurationSeconds: 14.0,
                    contextualStrings: [],
                    enableEtiquetteReplacements: false
                )

                let t0 = Date()
                let segments = try await SpeechRecognitionService.transcribeFile(
                    url: targetURL,
                    config: config
                ) { update in
                    // Silent progress or occasional log
                    _ = update
                }
                let elapsed = Date().timeIntervalSince(t0)

                print("\n=== Transcription & Speaker Diarization Result (\(segments.count) segments in \(String(format: "%.2f", elapsed))s) ===")
                for seg in segments {
                    let f0Str = seg.embedding.map { String(format: "%.0fHz", $0.f0Median) } ?? "N/A"
                    print("[\(seg.formattedTimeRange)] [話者 \(seg.speakerID) (\(f0Str))] \(seg.text)")
                }

                print("\n=== SRT Export Preview (First 3 items) ===")
                let srt = ExportService.formatTranscript(
                    segments: Array(segments.prefix(3)),
                    speakerNames: [:],
                    mediaInfo: info,
                    format: .srt,
                    options: ExportOptions(includeTimestamps: true, includeSpeakers: true, mergeConsecutiveSameSpeaker: false)
                )
                print(srt)
                exit(0)
            } catch {
                fputs("CLI Verification Error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
        fatalError("Unreachable")
    }
}

// MARK: - Native Window Screenshot Generator

enum ScreenshotCaptureRunner {
    static func runAndExit(outputPath: String, mediaPath: String?) -> Never {
        Task { @MainActor in
            do {
                NSApplication.shared.setActivationPolicy(.regular)
                let vm = AppViewModel()
                await vm.refreshLocales()

                if let path = mediaPath, FileManager.default.fileExists(atPath: path) {
                    let inputURL = URL(fileURLWithPath: path)
                    let info = try await MediaInspector.inspect(url: inputURL)
                    vm.mediaInfo = info
                    vm.playerManager.load(url: inputURL, durationSeconds: info.durationSeconds)
                    vm.playerManager.currentTime = 72.5

                    let reader = try await MediaInspector.prepareAudioReader(for: inputURL)
                    vm.waveformPeaks = reader.extractWaveformEnvelope(bucketCount: 140)

                    // Transcribe first 120s of the file for the screenshot
                    let clipSec = min(120.0, info.durationSeconds)
                    if let slice = reader.readMonoSamples(startTime: 0, endTime: clipSec, maxDuration: clipSec + 1.0),
                       let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(slice.sampleRate), channels: 1, interleaved: false),
                       let pcmBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(slice.samples.count)),
                       let ch0 = pcmBuf.floatChannelData?[0] {
                        pcmBuf.frameLength = AVAudioFrameCount(slice.samples.count)
                        _ = slice.samples.withUnsafeBufferPointer { src in
                            memcpy(ch0, src.baseAddress!, slice.samples.count * MemoryLayout<Float>.size)
                        }
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shot_clip_\(UUID().uuidString).wav")
                        defer { try? FileManager.default.removeItem(at: tmp) }
                        do {
                            let outFile = try AVAudioFile(forWriting: tmp, settings: fmt.settings)
                            try outFile.write(from: pcmBuf)
                        }
                        let config = TranscriptionConfig(
                            engine: .speechTranscriber,
                            localeIdentifier: "ja_JP",
                            speakerMode: .auto,
                            pauseThresholdSeconds: 0.45,
                            maxSegmentDurationSeconds: 14.0,
                            contextualStrings: [],
                            enableEtiquetteReplacements: false
                        )
                        let t0 = Date()
                        let segs = try await SpeechRecognitionService.transcribeFile(url: tmp, config: config) { _ in }
                        let elapsed = Date().timeIntervalSince(t0)
                        vm.segments = segs
                        vm.progressFraction = 1.0
                        vm.processingSpeedMultiplier = clipSec / max(0.1, elapsed)
                        vm.statusMessage = String(
                            format: "文字起こし完了 • %d セグメント • 処理時間 %.1f秒 (%.1fx 倍速)",
                            segs.count,
                            elapsed,
                            vm.processingSpeedMultiplier
                        )
                    }
                }

                let winRect = NSRect(x: 100, y: 100, width: 1180, height: 780)
                let window = NSWindow(
                    contentRect: winRect,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "LocalSpeechSTT — ローカル音声・動画文字起こし (Apple Speech)"
                let hostingView = NSHostingView(rootView: ContentView(viewModel: vm))
                hostingView.frame = winRect
                window.contentView = hostingView
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)

                // Let SwiftUI & AppKit complete layout passes
                try await Task.sleep(nanoseconds: 1_200_000_000)
                hostingView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(nanoseconds: 400_000_000)

                guard let contentView = window.contentView else {
                    fputs("No contentView\n", stderr)
                    exit(1)
                }
                let bounds = contentView.bounds
                guard let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
                    fputs("Failed to create bitmapImageRep\n", stderr)
                    exit(1)
                }
                contentView.cacheDisplay(in: bounds, to: rep)
                guard let pngData = rep.representation(using: .png, properties: [:]) else {
                    fputs("Failed to encode PNG\n", stderr)
                    exit(1)
                }
                let outURL = URL(fileURLWithPath: outputPath)
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try pngData.write(to: outURL)
                print("Saved screenshot to: \(outputPath)")
                exit(0)
            } catch {
                fputs("Screenshot Error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
        fatalError("Unreachable")
    }
}
