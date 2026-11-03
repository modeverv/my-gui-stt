import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

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
            if oldValue != speakerMode && !segments.isEmpty && !isTranscribing {
                reclusterSpeakersImmediately()
            }
        }
    }
    @Published var isReclustering: Bool = false
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

    @Published var segments: [TranscriptSegment] = [] {
        didSet { updateActivePlayingSegment() }
    }
    @Published var speakerNames: [Int: String] = [:]

    // MARK: - UI View & Filter State
    @Published var viewMode: TranscriptViewMode = .timeline
    @Published var searchQuery: String = ""
    @Published var selectedSpeakerFilter: Int? = nil
    @Published var showTimestamps: Bool = true
    @Published var showSpeakers: Bool = true
    @Published var mergeConsecutiveSameSpeaker: Bool = false {
        didSet { updateActivePlayingSegment() }
    }
    @Published var previewExportFormat: ExportFormat = .txt
    @Published var copyFeedbackBanner: String?
    /// Segment (in the currently displayed list) that contains the playback position
    @Published private(set) var activePlayingSegmentID: UUID?

    let playerManager = MediaPlayerManager()
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionStartTimestamp: Date?
    /// Incremented for every transcription run / file load so that late callbacks of stale tasks are ignored
    private var transcriptionRunID = 0
    private var mediaLoadID = 0
    private var reclusterTask: Task<Void, Never>?
    /// Frame-level acoustic features of the current file, kept for instant re-clustering
    private var diarizationFeatures: DiarizationFeatures?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        playerManager.$currentTime
            .removeDuplicates()
            .sink { [weak self] time in
                self?.updateActivePlayingSegment(at: time)
            }
            .store(in: &cancellables)

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

    private func updateActivePlayingSegment(at time: Double? = nil) {
        let t = time ?? playerManager.currentTime
        var newID: UUID?
        if t > 0 || playerManager.isPlaying,
           let idx = segments.lastIndex(where: { t >= $0.startTime && t <= $0.endTime + 0.15 }) {
            if mergeConsecutiveSameSpeaker {
                // The merged row keeps the id of the first segment of its group (see ExportService.mergeConsecutiveBySpeaker)
                var first = idx
                while first > 0,
                      segments[first - 1].speakerID == segments[first].speakerID,
                      segments[first].startTime - segments[first - 1].endTime < 4.0 {
                    first -= 1
                }
                newID = segments[first].id
            } else {
                newID = segments[idx].id
            }
        }
        if newID != activePlayingSegmentID {
            activePlayingSegmentID = newID
        }
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
            // Word timings no longer match the edited text
            segments[idx].tokens = nil
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

        if let current = mediaInfo?.url {
            panel.directoryURL = current.deletingLastPathComponent()
        }

        // Cancelling the panel must leave the currently loaded file, player and transcript untouched
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await loadMediaFile(url: url)
        }
    }

    func loadMediaFile(url: URL) async {
        mediaLoadID += 1
        let loadID = mediaLoadID
        let previousStatus = statusMessage
        errorMessage = nil
        statusMessage = "メディアファイルを解析しています..."

        let info: MediaFileInfo
        do {
            info = try await MediaInspector.inspect(url: url)
        } catch {
            guard loadID == mediaLoadID else { return }
            // Keep the previously loaded file fully usable
            errorMessage = "ファイルを読み込めませんでした (\(url.lastPathComponent)): \(error.localizedDescription)"
            statusMessage = mediaInfo != nil ? previousStatus : "ファイルの読み込みに失敗しました"
            return
        }
        // A newer load request superseded this one
        guard loadID == mediaLoadID else { return }

        cancelTranscription()
        reclusterTask?.cancel()
        reclusterTask = nil
        isReclustering = false

        mediaInfo = info
        waveformPeaks = []
        segments = []
        speakerNames = [:]
        selectedSpeakerFilter = nil
        searchQuery = ""
        diarizationFeatures = nil
        progressFraction = 0
        processedSeconds = 0
        processingSpeedMultiplier = 0
        lastElapsedTimeSeconds = nil
        activePlayingSegmentID = nil
        playerManager.load(url: url, durationSeconds: info.durationSeconds)
        statusMessage = "準備完了: \(info.fileName) (\(info.formattedDuration))"

        // Extract waveform in background
        Task { [weak self] in
            let peaks = await Task.detached(priority: .utility) { () -> [Float]? in
                guard let reader = try? await MediaInspector.prepareAudioReader(for: url) else { return nil }
                return reader.extractWaveformEnvelope(bucketCount: 140)
            }.value
            guard let self, let peaks, loadID == self.mediaLoadID else { return }
            self.waveformPeaks = peaks
        }
    }

    // MARK: - Speaker Re-Clustering (Instant)

    func reclusterSpeakersImmediately() {
        guard !segments.isEmpty else { return }
        reclusterTask?.cancel()

        let mode = speakerMode
        let input = segments
        guard let features = diarizationFeatures else {
            // Fallback: utterance-level clustering (no frame features available)
            var copy = input
            SpeakerDiarizer.assignSpeakers(segments: &copy, mode: mode)
            applyReclusteredSegments(copy)
            return
        }

        isReclustering = true
        let runID = transcriptionRunID
        reclusterTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                DiarizationEngine.diarize(segments: input, features: features, mode: mode)
            }.value
            guard let self, !Task.isCancelled, runID == self.transcriptionRunID, self.speakerMode == mode else { return }
            self.isReclustering = false
            self.applyReclusteredSegments(result)
        }
    }

    private func applyReclusteredSegments(_ newSegments: [TranscriptSegment]) {
        segments = newSegments
        if let spkFilter = selectedSpeakerFilter, !detectedSpeakers.contains(where: { $0.id == spkFilter }) {
            selectedSpeakerFilter = nil
        }
        updateActivePlayingSegment()
    }

    // MARK: - Start / Stop Transcription

    func startTranscription() {
        guard let info = mediaInfo else { return }
        cancelTranscription()
        reclusterTask?.cancel()
        reclusterTask = nil
        isReclustering = false

        transcriptionRunID += 1
        let runID = transcriptionRunID
        isTranscribing = true
        progressFraction = 0.0
        processedSeconds = 0.0
        volatilePreviewText = ""
        errorMessage = nil
        segments = []
        diarizationFeatures = nil
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
                        // Ignore late updates from a cancelled / superseded run
                        guard let self = self, self.isTranscribing, runID == self.transcriptionRunID else { return }
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

                guard !Task.isCancelled, runID == self.transcriptionRunID else { return }
                let elapsed = Date().timeIntervalSince(startTime)
                self.diarizationFeatures = finalResult.diarizationFeatures
                self.segments = finalResult.segments
                self.isTranscribing = false
                self.progressFraction = 1.0
                self.volatilePreviewText = ""
                self.lastElapsedTimeSeconds = elapsed
                if elapsed > 0.1 {
                    self.processingSpeedMultiplier = info.durationSeconds / elapsed
                }
                self.statusMessage = String(
                    format: "文字起こし完了 • %d セグメント • 処理時間 %.1f秒 (%.1fx 倍速)",
                    finalResult.segments.count,
                    elapsed,
                    self.processingSpeedMultiplier
                )
                self.updateActivePlayingSegment()
                // The speaker mode may have been changed while the run was in progress
                if self.speakerMode != config.speakerMode {
                    self.reclusterSpeakersImmediately()
                }
            } catch {
                // A stale run must not touch the state of a newer run (cancelTranscription already updated the UI)
                guard runID == self.transcriptionRunID else { return }
                self.isTranscribing = false
                self.volatilePreviewText = ""
                if error is CancellationError || Task.isCancelled {
                    self.statusMessage = "文字起こしを停止しました (\(self.segments.count) セグメント保持)"
                } else {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "エラーが発生しました"
                }
            }
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if isTranscribing {
            // Invalidate the running task so its late callbacks are ignored
            transcriptionRunID += 1
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
