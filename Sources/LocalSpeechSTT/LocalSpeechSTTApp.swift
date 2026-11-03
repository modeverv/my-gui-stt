import SwiftUI
import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened via Finder / `open -a` can arrive before the window (and this handler) exists;
    /// they are buffered and delivered as soon as the handler is installed.
    var onOpenURLs: (([URL]) -> Void)? {
        didSet {
            if let handler = onOpenURLs, !pendingURLs.isEmpty {
                let urls = pendingURLs
                pendingURLs = []
                handler(urls)
            }
        }
    }
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler = onOpenURLs {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
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

        // Support "--cli <filepath> [--max-seconds <N>] [--speakers <N>] [--json-out <path>]"
        // for automated verification & batch processing
        func optionValue(_ name: String) -> String? {
            guard let idx = args.firstIndex(of: name), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }
        let speakerMode = optionValue("--speakers").flatMap(Int.init).flatMap(SpeakerCountMode.init(rawValue:)) ?? .auto

        if let filePath = optionValue("--cli") {
            CLIVerificationRunner.runAndExit(
                filePath: filePath,
                maxSeconds: optionValue("--max-seconds").flatMap(Double.init),
                speakerMode: speakerMode,
                jsonOutPath: optionValue("--json-out")
            )
        }

        // Support "--diarize <segments.json> <media>" to re-run speaker diarization on a saved transcript
        if let idx = args.firstIndex(of: "--diarize"), idx + 2 < args.count {
            CLIVerificationRunner.rediarizeAndExit(
                segmentsJSONPath: args[idx + 1],
                mediaPath: args[idx + 2],
                speakerMode: speakerMode
            )
        }
    }

    var body: some Scene {
        // Single main window: the app has one shared AppViewModel, so multiple windows would fight over it
        Window("LocalSpeechSTT — ローカル音声・動画文字起こし (Apple Speech)", id: "main") {
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
    static func rediarizeAndExit(segmentsJSONPath: String, mediaPath: String, speakerMode: SpeakerCountMode) -> Never {
        Task {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: segmentsJSONPath))
                let segments = try JSONDecoder().decode([TranscriptSegment].self, from: data)
                let reader = try await MediaInspector.prepareAudioReader(for: URL(fileURLWithPath: mediaPath))
                let t0 = Date()
                let features = try DiarizationEngine.extractFeatures(url: reader.audioFileURL)
                let t1 = Date()
                let result = DiarizationEngine.diarize(segments: segments, features: features, mode: speakerMode)
                let t2 = Date()
                printSegments(result)
                print(String(format: "\n=== %d -> %d segments, features %.2fs, diarization %.2fs ===",
                             segments.count, result.count, t1.timeIntervalSince(t0), t2.timeIntervalSince(t1)))
                printSpeakerSummary(result)
                exit(0)
            } catch {
                fputs("Diarization Error: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        RunLoop.main.run()
        fatalError("Unreachable")
    }

    private static func printSegments(_ segments: [TranscriptSegment]) {
        for seg in segments {
            print("[\(seg.formattedTimeRange)] [話者 \(seg.speakerID)] \(seg.text)")
        }
    }

    private static func printSpeakerSummary(_ segments: [TranscriptSegment]) {
        var totals: [Int: (count: Int, seconds: Double)] = [:]
        for seg in segments {
            let cur = totals[seg.speakerID] ?? (0, 0)
            totals[seg.speakerID] = (cur.count + 1, cur.seconds + seg.duration)
        }
        for spk in totals.keys.sorted() {
            let v = totals[spk]!
            print(String(format: "話者 %d: %d セグメント, %.1f 秒", spk, v.count, v.seconds))
        }
    }

    static func runAndExit(filePath: String, maxSeconds: Double?, speakerMode: SpeakerCountMode, jsonOutPath: String?) -> Never {
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
                    speakerMode: speakerMode,
                    pauseThresholdSeconds: 0.45,
                    maxSegmentDurationSeconds: 14.0,
                    contextualStrings: [],
                    enableEtiquetteReplacements: false
                )

                let t0 = Date()
                let result = try await SpeechRecognitionService.transcribeFile(
                    url: targetURL,
                    config: config
                ) { update in
                    // Silent progress or occasional log
                    _ = update
                }
                let segments = result.segments
                let elapsed = Date().timeIntervalSince(t0)

                if let jsonOutPath {
                    // Raw (pre-diarization speaker IDs are irrelevant) segments incl. tokens for --diarize experiments
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted]
                    try encoder.encode(segments).write(to: URL(fileURLWithPath: jsonOutPath))
                }

                print("\n=== Transcription & Speaker Diarization Result (\(segments.count) segments in \(String(format: "%.2f", elapsed))s) ===")
                for seg in segments {
                    let f0Str = seg.embedding.map { String(format: "%.0fHz", $0.f0Median) } ?? "N/A"
                    print("[\(seg.formattedTimeRange)] [話者 \(seg.speakerID) (\(f0Str))] \(seg.text)")
                }

                printSpeakerSummary(segments)

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
                        let segs = try await SpeechRecognitionService.transcribeFile(url: tmp, config: config) { _ in }.segments
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
