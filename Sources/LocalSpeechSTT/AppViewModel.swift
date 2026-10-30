import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum TranscriptViewMode: String, CaseIterable, Identifiable {
    case timeline = "タイムライン編集"
    case fullText = "全文プレビュー"

    var id: String { rawValue }
}

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Media & Waveform State
    @Published var mediaInfo: MediaFileInfo?
    @Published var waveformPeaks: [Float] = []
    @Published var isDropTargeted: Bool = false

    // MARK: - Settings State
    @Published var selectedEngine: TranscriptionEngineType = .speechTranscriber {
        didSet {
            if oldValue != selectedEngine {
                Task { await refreshLocales() }
            }
        }
    }
    @Published var availableLocales: [SupportedLocaleItem] = []
    @Published var selectedLocaleID: String = "ja_JP"
    @Published var speakerMode: SpeakerCountMode = .auto {
        didSet {
            if oldValue != speakerMode && !segments.isEmpty {
                reclusterSpeakersImmediately()
            }
        }
    }
    @Published var pauseThresholdSeconds: Double = 0.45
    @Published var maxSegmentDurationSeconds: Double = 14.0
    @Published var customVocabularyInput: String = ""
    @Published var enableEtiquetteReplacements: Bool = false

    // MARK: - Transcription Progress & Results
    @Published var isTranscribing: Bool = false
    @Published var progressFraction: Double = 0.0
    @Published var processedSeconds: Double = 0.0
    @Published var volatilePreviewText: String = ""
    @Published var statusMessage: String = "動画または音声ファイルを選択してください"
    @Published var errorMessage: String?
    @Published var processingSpeedMultiplier: Double = 0.0
    @Published var lastElapsedTimeSeconds: Double?

    @Published var segments: [TranscriptSegment] = []
    @Published var speakerNames: [Int: String] = [:]

    // MARK: - UI View & Filter State
    @Published var viewMode: TranscriptViewMode = .timeline
    @Published var searchQuery: String = ""
    @Published var selectedSpeakerFilter: Int? = nil
    @Published var showTimestamps: Bool = true
    @Published var showSpeakers: Bool = true
    @Published var mergeConsecutiveSameSpeaker: Bool = false
    @Published var previewExportFormat: ExportFormat = .txt
    @Published var copyFeedbackBanner: String?

    let playerManager = MediaPlayerManager()
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionStartTimestamp: Date?

    init() {
        Task {
            await refreshLocales()
            // Check if a file path was passed via command line arguments
            let args = CommandLine.arguments
            if args.count > 1 {
                let candidateURL = URL(fileURLWithPath: args[1])
                if FileManager.default.fileExists(atPath: candidateURL.path) {
                    await loadMediaFile(url: candidateURL)
                }
            }
        }
    }

    // MARK: - Computed Properties

    var detectedSpeakers: [SpeakerInfo] {
        guard !segments.isEmpty else { return [] }
        var grouped: [Int: [TranscriptSegment]] = [:]
        for seg in segments {
            grouped[seg.speakerID, default: []].append(seg)
        }
        return grouped.keys.sorted().map { spkID in
            let list = grouped[spkID] ?? []
            let f0s = list.compactMap { $0.embedding?.f0Median }
            let avgF0: Float? = f0s.isEmpty ? nil : (f0s.reduce(0, +) / Float(f0s.count))
            let totalDur = list.reduce(0.0) { $0 + $1.duration }
            let name = speakerDisplayName(for: spkID)
            return SpeakerInfo(
                id: spkID,
                name: name,
                averageF0: avgF0,
                segmentCount: list.count,
                totalDuration: totalDur
            )
        }
    }

    var filteredSegments: [TranscriptSegment] {
        var base = mergeConsecutiveSameSpeaker
            ? ExportService.mergeConsecutiveBySpeaker(segments: segments)
            : segments

        if let spk = selectedSpeakerFilter {
            base = base.filter { $0.speakerID == spk }
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            base = base.filter { seg in
                seg.text.localizedCaseInsensitiveContains(trimmedQuery) ||
                speakerDisplayName(for: seg.speakerID).localizedCaseInsensitiveContains(trimmedQuery) ||
                seg.formattedTimeRange.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }
        return base
    }

    var formattedFullTextPreview: String {
        ExportService.formatTranscript(
            segments: filteredSegments,
            speakerNames: speakerNames,
            mediaInfo: mediaInfo,
            format: previewExportFormat,
            options: ExportOptions(
                includeTimestamps: showTimestamps,
                includeSpeakers: showSpeakers && speakerMode != .off,
                mergeConsecutiveSameSpeaker: mergeConsecutiveSameSpeaker
            )
        )
    }

    var totalCharacterCount: Int {
        segments.reduce(0) { $0 + $1.text.count }
    }

    var activePlayingSegmentID: UUID? {
        guard playerManager.isPlaying || playerManager.currentTime > 0 else { return nil }
        let t = playerManager.currentTime
        return segments.first(where: { t >= $0.startTime && t <= $0.endTime + 0.15 })?.id
    }

    func speakerDisplayName(for speakerID: Int) -> String {
        if let custom = speakerNames[speakerID], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return "話者 \(speakerID)"
    }

    func updateSpeakerName(speakerID: Int, newName: String) {
        speakerNames[speakerID] = newName
    }

    func updateSegmentSpeaker(segmentID: UUID, newSpeakerID: Int) {
        if let idx = segments.firstIndex(where: { $0.id == segmentID }) {
            segments[idx].speakerID = newSpeakerID
        }
    }

    func updateSegmentText(segmentID: UUID, newText: String) {
        if let idx = segments.firstIndex(where: { $0.id == segmentID }) {
            segments[idx].text = newText
        }
    }

    // MARK: - Locale Loading

    func refreshLocales() async {
        let items = await SpeechRecognitionService.loadAvailableLocales(for: selectedEngine)
        availableLocales = items
        let currentNorm = selectedLocaleID.replacingOccurrences(of: "-", with: "_")
        if let match = items.first(where: { $0.identifier.replacingOccurrences(of: "-", with: "_") == currentNorm }) {
            selectedLocaleID = match.identifier
        } else if let ja = items.first(where: { $0.identifier.hasPrefix("ja") }) {
            selectedLocaleID = ja.identifier
        } else if let first = items.first {
            selectedLocaleID = first.identifier
        }
    }

    // MARK: - File Opening & Drag-and-Drop

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "文字起こしする動画・音声ファイルを選択"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audiovisualContent,
            .audio,
            .movie,
            .video,
            .mpeg4Movie,
            .quickTimeMovie,
            .mpeg4Audio,
            .mp3,
            .wav,
            .aiff
        ]

        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await loadMediaFile(url: url)
            }
        }
    }

    func loadMediaFile(url: URL) async {
        cancelTranscription()
        errorMessage = nil
        statusMessage = "メディアファイルを解析しています..."

        do {
            let info = try await MediaInspector.inspect(url: url)
            mediaInfo = info
            playerManager.load(url: url, durationSeconds: info.durationSeconds)
            statusMessage = "準備完了: \(info.fileName) (\(info.formattedDuration))"

            // Extract waveform in background
            Task.detached(priority: .utility) {
                if let reader = try? await MediaInspector.prepareAudioReader(for: url) {
                    let peaks = reader.extractWaveformEnvelope(bucketCount: 140)
                    await MainActor.run {
                        self.waveformPeaks = peaks
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "ファイルの読み込みに失敗しました"
        }
    }

    // MARK: - Speaker Re-Clustering (Instant)

    func reclusterSpeakersImmediately() {
        guard !segments.isEmpty else { return }
        var copy = segments
        SpeakerDiarizer.assignSpeakers(segments: &copy, mode: speakerMode)
        segments = copy
        if let spkFilter = selectedSpeakerFilter, !detectedSpeakers.contains(where: { $0.id == spkFilter }) {
            selectedSpeakerFilter = nil
        }
    }

    // MARK: - Start / Stop Transcription

    func startTranscription() {
        guard let info = mediaInfo else { return }
        cancelTranscription()

        isTranscribing = true
        progressFraction = 0.0
        processedSeconds = 0.0
        volatilePreviewText = ""
        errorMessage = nil
        segments = []
        selectedSpeakerFilter = nil
        processingSpeedMultiplier = 0.0
        lastElapsedTimeSeconds = nil
        let startTime = Date()
        transcriptionStartTimestamp = startTime

        let customTerms = customVocabularyInput
            .components(separatedBy: CharacterSet(charactersIn: ",、\n\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let config = TranscriptionConfig(
            engine: selectedEngine,
            localeIdentifier: selectedLocaleID,
            speakerMode: speakerMode,
            pauseThresholdSeconds: pauseThresholdSeconds,
            maxSegmentDurationSeconds: maxSegmentDurationSeconds,
            contextualStrings: customTerms,
            enableEtiquetteReplacements: enableEtiquetteReplacements
        )

        transcriptionTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let finalResult = try await SpeechRecognitionService.transcribeFile(
                    url: info.url,
                    config: config
                ) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.isTranscribing else { return }
                        self.processedSeconds = update.processedSeconds
                        self.progressFraction = update.fractionCompleted
                        self.volatilePreviewText = update.volatilePreviewText
                        self.statusMessage = update.statusMessage

                        if let start = self.transcriptionStartTimestamp {
                            let elapsed = Date().timeIntervalSince(start)
                            if elapsed > 0.3 && update.processedSeconds > 0 {
                                self.processingSpeedMultiplier = update.processedSeconds / elapsed
                            }
                        }

                        if let updatedSegments = update.finalizedSegments {
                            self.segments = updatedSegments
                        }
                    }
                }

                guard !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(startTime)
                self.segments = finalResult
                self.isTranscribing = false
                self.progressFraction = 1.0
                self.volatilePreviewText = ""
                self.lastElapsedTimeSeconds = elapsed
                if elapsed > 0.1 {
                    self.processingSpeedMultiplier = info.durationSeconds / elapsed
                }
                self.statusMessage = String(
                    format: "文字起こし完了 • %d セグメント • 処理時間 %.1f秒 (%.1fx 倍速)",
                    finalResult.count,
                    elapsed,
                    self.processingSpeedMultiplier
                )
            } catch is CancellationError {
                self.isTranscribing = false
                self.volatilePreviewText = ""
                self.statusMessage = "文字起こしを停止しました (\(self.segments.count) セグメント保持)"
            } catch {
                self.isTranscribing = false
                self.volatilePreviewText = ""
                self.errorMessage = error.localizedDescription
                self.statusMessage = "エラーが発生しました"
            }
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if isTranscribing {
            isTranscribing = false
            volatilePreviewText = ""
            statusMessage = "文字起こしを停止しました (\(segments.count) セグメント保持)"
        }
    }

    // MARK: - Copy & Export Actions

    func copyTranscriptToClipboard(format: ExportFormat? = nil) {
        let targetFormat = format ?? (viewMode == .fullText ? previewExportFormat : .txt)
        let content = ExportService.formatTranscript(
            segments: filteredSegments,
            speakerNames: speakerNames,
            mediaInfo: mediaInfo,
            format: targetFormat,
            options: ExportOptions(
                includeTimestamps: showTimestamps,
                includeSpeakers: showSpeakers && speakerMode != .off,
                mergeConsecutiveSameSpeaker: mergeConsecutiveSameSpeaker
            )
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)

        copyFeedbackBanner = "クリップボードにコピーしました (\(targetFormat.displayName))"
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.copyFeedbackBanner?.contains("コピーしました") == true {
                self.copyFeedbackBanner = nil
            }
        }
    }

    func exportTranscriptToFile(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = "文字起こし結果を保存 (\(format.displayName))"
        panel.canCreateDirectories = true

        let baseName = mediaInfo?.url.deletingPathExtension().lastPathComponent ?? "transcript"
        panel.nameFieldStringValue = "\(baseName)_transcript.\(format.fileExtension)"

        if panel.runModal() == .OK, let destURL = panel.url {
            let content = ExportService.formatTranscript(
                segments: filteredSegments,
                speakerNames: speakerNames,
                mediaInfo: mediaInfo,
                format: format,
                options: ExportOptions(
                    includeTimestamps: showTimestamps,
                    includeSpeakers: showSpeakers && speakerMode != .off,
                    mergeConsecutiveSameSpeaker: mergeConsecutiveSameSpeaker
                )
            )
            do {
                try content.write(to: destURL, atomically: true, encoding: .utf8)
                copyFeedbackBanner = "保存完了: \(destURL.lastPathComponent)"
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.copyFeedbackBanner = nil
                }
            } catch {
                errorMessage = "ファイルの保存に失敗しました: \(error.localizedDescription)"
            }
        }
    }
}
