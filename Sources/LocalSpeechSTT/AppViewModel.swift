import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

enum TranscriptViewMode: String, CaseIterable, Identifiable {
    case timeline = "タイムライン編集"
    case fullText = "全文プレビュー"
    case review = "補正レビュー"

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

    // MARK: - High-Accuracy Refinement & Human Review State
    @Published var isRefining: Bool = false
    @Published var suggestions: [CorrectionSuggestion] = []
    @Published var glossary: Glossary = Glossary.load()
    private var refineTask: Task<Void, Never>?
    /// Segments as they were before a suggestion was applied, so that it can be undone
    private var undoSnapshots: [UUID: [TranscriptSegment]] = [:]

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
        cancelRefinement()
        suggestions = []
        undoSnapshots = [:]
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
        cancelRefinement()
        suggestions = []
        undoSnapshots = [:]
        if viewMode == .review { viewMode = .timeline }
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
            // Approved glossary terms help the recognizer spell them correctly in the first place
            + glossary.approved.map(\.to).filter { !$0.isEmpty }

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
                let (glossed, glossaryHits) = self.applyApprovedGlossary(to: finalResult.segments)
                self.segments = glossed
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
                ) + (glossaryHits > 0 ? " • 用語辞書を \(glossaryHits) 箇所に適用" : "")
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

    // MARK: - High-Accuracy Refinement (Whisper + neural speakers + local LLM)

    var canRefine: Bool {
        mediaInfo != nil && !segments.isEmpty && !isTranscribing && !isRefining && !isReclustering
    }

    var pendingSuggestionCount: Int {
        suggestions.filter { $0.status == .pending }.count
    }

    func startRefinement() {
        guard canRefine, let media = mediaInfo?.url else { return }
        let input = segments
        let mode = speakerMode
        let glossarySnapshot = glossary
        let runID = transcriptionRunID
        let startedAt = Date()
        isRefining = true
        errorMessage = nil
        progressFraction = 0
        statusMessage = "高精度補正を準備しています..."

        let onProgress: @Sendable (Double, String) -> Void = { [weak self] fraction, message in
            Task { @MainActor [weak self] in
                guard let self, self.isRefining else { return }
                self.progressFraction = fraction
                self.statusMessage = "高精度補正: " + message
            }
        }
        refineTask = Task { [weak self] in
            do {
                let review = try await RefinementService.run(
                    media: media,
                    segments: input,
                    speakerMode: mode,
                    glossary: glossarySnapshot,
                    onProgress: onProgress
                )
                guard let self, !Task.isCancelled, runID == self.transcriptionRunID else { return }
                self.isRefining = false
                self.progressFraction = 1
                self.segments = review.segments
                self.suggestions = review.suggestions.sorted(by: Self.reviewOrder)
                self.undoSnapshots = [:]
                self.viewMode = .review
                let minutes = Date().timeIntervalSince(startedAt) / 60
                self.statusMessage = String(
                    format: "高精度補正完了 • 確認待ち %d 件 • 辞書を %d 箇所に適用 • %.1f 分",
                    self.pendingSuggestionCount, review.autoAppliedTerms.count, minutes
                )
            } catch {
                guard let self, runID == self.transcriptionRunID else { return }
                self.isRefining = false
                if error is CancellationError || Task.isCancelled {
                    self.statusMessage = "高精度補正を中止しました"
                } else {
                    self.errorMessage = error.localizedDescription
                    self.statusMessage = "高精度補正に失敗しました"
                }
            }
        }
    }

    func cancelRefinement() {
        refineTask?.cancel()
        refineTask = nil
        if isRefining {
            isRefining = false
            statusMessage = "高精度補正を中止しました"
        }
    }

    /// Terms first (one decision fixes many places), then speakers, then LLM-recommended spans.
    static func reviewOrder(_ a: CorrectionSuggestion, _ b: CorrectionSuggestion) -> Bool {
        func rank(_ s: CorrectionSuggestion) -> Int {
            switch s.kind {
            case .term: return 0
            case .speaker: return 1
            case .span: return s.recommended == true ? 2 : 3
            }
        }
        return rank(a) < rank(b)
    }

    func segment(withID id: UUID?) -> TranscriptSegment? {
        guard let id else { return nil }
        return segments.first { $0.id == id }
    }

    // MARK: - Human Review Actions

    /// Accepts a suggestion. `customText` replaces the candidate with what the reviewer typed.
    func acceptSuggestion(_ suggestionID: UUID, customText: String? = nil) {
        guard let si = suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        let sug = suggestions[si]
        let custom = customText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let useCustom = !(custom ?? "").isEmpty

        switch sug.kind {
        case .term:
            guard let from = sug.original, let to = useCustom ? custom : sug.candidate else { return }
            undoSnapshots[sug.id] = replaceEverywhere(from, with: to)
            // Risky (short) terms fix this transcript only and are not remembered for future files
            if TermReplacer.glossaryRisk(for: from) == nil {
                glossary.approve(from: from, to: to)
                glossary.save()
            }
        case .span:
            guard let segID = sug.segmentID, let idx = segments.firstIndex(where: { $0.id == segID }),
                  let original = sug.original, let replacement = useCustom ? custom : sug.candidate else { return }
            guard let newText = Self.replacing(original, at: sug.offset, with: replacement, in: segments[idx].text) else {
                errorMessage = "この箇所は既に編集されているため適用できませんでした: 「\(original)」"
                return
            }
            undoSnapshots[sug.id] = [segments[idx]]
            segments[idx].text = newText
            segments[idx].tokens = nil
        case .speaker:
            guard let segID = sug.segmentID, let idx = segments.firstIndex(where: { $0.id == segID }),
                  let alt = sug.alternative else { return }
            undoSnapshots[sug.id] = [segments[idx]]
            segments[idx].speakerID = alt
        }
        suggestions[si].status = useCustom ? .edited : .accepted
        suggestions[si].resolvedText = useCustom ? custom : nil
    }

    func rejectSuggestion(_ suggestionID: UUID) {
        guard let si = suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        let sug = suggestions[si]
        if sug.kind == .term, let from = sug.original, let to = sug.candidate {
            glossary.reject(from: from, to: to)
            glossary.save()
        }
        suggestions[si].status = .rejected
    }

    func undoSuggestion(_ suggestionID: UUID) {
        guard let si = suggestions.firstIndex(where: { $0.id == suggestionID }) else { return }
        let sug = suggestions[si]
        for old in undoSnapshots[sug.id] ?? [] {
            if let idx = segments.firstIndex(where: { $0.id == old.id }) {
                segments[idx] = old
            }
        }
        undoSnapshots[sug.id] = nil
        if sug.kind == .term, let from = sug.original {
            let to = sug.resolvedText ?? sug.candidate ?? ""
            glossary.approved.removeAll { $0.from == from && $0.to == to }
            glossary.rejected.removeAll { $0.from == from && $0.to == (sug.candidate ?? "") }
            glossary.save()
        }
        suggestions[si].status = .pending
        suggestions[si].resolvedText = nil
    }

    /// "This is wrong, it should be ..." — the reviewer's own correction, applied to the whole transcript
    /// and remembered in the glossary for future files.
    @discardableResult
    func applyManualCorrection(from: String, to: String) -> (count: Int, savedToGlossary: Bool) {
        let from = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, from != to else { return (0, false) }
        let count = occurrenceCount(of: from)
        guard count > 0 else { return (0, false) }
        let risky = TermReplacer.glossaryRisk(for: from) != nil
        let sug = CorrectionSuggestion(
            id: UUID(), kind: .term, status: .edited,
            segmentIDs: segments.filter { TermReplacer.occurrences(of: from, in: $0.text) > 0 }.map(\.id),
            original: from, candidate: to, recommended: nil,
            note: risky ? "手動で指摘 (この書き起こしのみ・辞書には未登録)" : "手動で指摘", resolvedText: to
        )
        undoSnapshots[sug.id] = replaceEverywhere(from, with: to)
        suggestions.insert(sug, at: 0)
        if !risky {
            glossary.approve(from: from, to: to)
            glossary.save()
        }
        return (count, !risky)
    }

    func occurrenceCount(of term: String) -> Int {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 0 }
        return segments.reduce(0) { $0 + TermReplacer.occurrences(of: t, in: $1.text) }
    }

    func removeGlossaryEntry(_ entry: GlossaryEntry) {
        glossary.approved.removeAll { $0 == entry }
        glossary.rejected.removeAll { $0 == entry }
        glossary.save()
    }

    /// Applies `from -> to` to every utterance and returns the previous versions of the changed ones.
    private func replaceEverywhere(_ from: String, with to: String) -> [TranscriptSegment] {
        var previous: [TranscriptSegment] = []
        for i in segments.indices {
            let newText = TermReplacer.replace(from, with: to, in: segments[i].text)
            if newText != segments[i].text {
                previous.append(segments[i])
                segments[i].text = newText
                segments[i].tokens = nil
            }
        }
        return previous
    }

    private func applyApprovedGlossary(to input: [TranscriptSegment]) -> ([TranscriptSegment], Int) {
        guard !glossary.approved.isEmpty else { return (input, 0) }
        var output = input
        var hits = 0
        for i in output.indices {
            let result = TermReplacer.apply(glossary.approved, to: output[i].text)
            if result.hits > 0 {
                hits += result.hits
                output[i].text = result.text
                output[i].tokens = nil
            }
        }
        return (output, hits)
    }

    /// Replaces `original` at the given Unicode-scalar offset, or at its first occurrence if the text moved.
    static func replacing(_ original: String, at offset: Int?, with replacement: String, in text: String) -> String? {
        let scalars = text.unicodeScalars
        if let offset, offset >= 0, offset + original.unicodeScalars.count <= scalars.count {
            let start = scalars.index(scalars.startIndex, offsetBy: offset)
            let end = scalars.index(start, offsetBy: original.unicodeScalars.count)
            if String(scalars[start..<end]) == original {
                var out = String.UnicodeScalarView()
                out.append(contentsOf: scalars[..<start])
                out.append(contentsOf: replacement.unicodeScalars)
                out.append(contentsOf: scalars[end...])
                return String(out)
            }
        }
        guard let range = text.range(of: original) else { return nil }
        return text.replacingCharacters(in: range, with: replacement)
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
