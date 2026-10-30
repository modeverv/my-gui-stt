import Foundation
import AVFoundation
import Speech
import CoreMedia

enum SpeechServiceError: LocalizedError {
    case localeNotSupported(String)
    case recognizerUnavailable(String)
    case authorizationDenied
    case cancelled

    var errorDescription: String? {
        switch self {
        case .localeNotSupported(let id):
            return "選択された言語 (\(id)) はこの音声認識エンジンでサポートされていません。"
        case .recognizerUnavailable(let msg):
            return "オンデバイス音声認識エンジンを利用できません: \(msg)"
        case .authorizationDenied:
            return "音声認識の権限が許可されていません。システム設定 > プライバシーとセキュリティ > 音声認識 を確認してください。"
        case .cancelled:
            return "処理がキャンセルされました。"
        }
    }
}

struct TranscriptionConfig: Sendable {
    var engine: TranscriptionEngineType
    var localeIdentifier: String
    var speakerMode: SpeakerCountMode
    var pauseThresholdSeconds: Double
    var maxSegmentDurationSeconds: Double
    var contextualStrings: [String]
    var enableEtiquetteReplacements: Bool
}

struct TranscriptionProgressUpdate: Sendable {
    var processedSeconds: Double
    var totalSeconds: Double
    var volatilePreviewText: String
    var statusMessage: String
    var finalizedSegments: [TranscriptSegment]?

    var fractionCompleted: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1.0, max(0.0, processedSeconds / totalSeconds))
    }
}

enum SpeechRecognitionService {

    // MARK: - Locale Discovery

    static func loadAvailableLocales(for engine: TranscriptionEngineType) async -> [SupportedLocaleItem] {
        let displayLocale = Locale(identifier: "ja_JP")

        switch engine {
        case .speechTranscriber:
            let supported = await SpeechTranscriber.supportedLocales
            let installedSet = Set((await SpeechTranscriber.installedLocales).map { normalizeLocaleID($0.identifier) })
            return buildSortedLocaleItems(locales: supported, installedIDs: installedSet, displayLocale: displayLocale)

        case .dictationTranscriber:
            let supported = await DictationTranscriber.supportedLocales
            let installedSet = Set((await DictationTranscriber.installedLocales).map { normalizeLocaleID($0.identifier) })
            return buildSortedLocaleItems(locales: supported, installedIDs: installedSet, displayLocale: displayLocale)

        case .sfSpeechRecognizer:
            let supported = Array(SFSpeechRecognizer.supportedLocales())
            var installedSet = Set<String>()
            for loc in supported {
                if let rec = SFSpeechRecognizer(locale: loc), rec.supportsOnDeviceRecognition {
                    installedSet.insert(normalizeLocaleID(loc.identifier))
                }
            }
            return buildSortedLocaleItems(locales: supported, installedIDs: installedSet, displayLocale: displayLocale)
        }
    }

    private static func normalizeLocaleID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "_")
    }

    private static func buildSortedLocaleItems(
        locales: [Locale],
        installedIDs: Set<String>,
        displayLocale: Locale
    ) -> [SupportedLocaleItem] {
        var seen = Set<String>()
        var items: [SupportedLocaleItem] = []

        for loc in locales {
            let normID = normalizeLocaleID(loc.identifier)
            guard !seen.contains(normID) else { continue }
            seen.insert(normID)

            let name = displayLocale.localizedString(forIdentifier: loc.identifier) ?? loc.identifier
            let isInstalled = installedIDs.contains(normID)
            items.append(SupportedLocaleItem(
                identifier: loc.identifier,
                displayName: name,
                isInstalled: isInstalled
            ))
        }

        let priorityOrder = ["ja_JP", "en_US", "en_GB", "zh_CN", "zh_TW", "ko_KR", "fr_FR", "de_DE", "es_ES"]
        items.sort { a, b in
            let na = normalizeLocaleID(a.identifier)
            let nb = normalizeLocaleID(b.identifier)
            let pa = priorityOrder.firstIndex(of: na) ?? Int.max
            let pb = priorityOrder.firstIndex(of: nb) ?? Int.max
            if pa != pb { return pa < pb }
            if a.isInstalled != b.isInstalled { return a.isInstalled && !b.isInstalled }
            return a.displayName < b.displayName
        }

        return items
    }

    // MARK: - Main Transcription Entrypoint

    static func transcribeFile(
        url: URL,
        config: TranscriptionConfig,
        onProgress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> [TranscriptSegment] {
        onProgress(TranscriptionProgressUpdate(
            processedSeconds: 0,
            totalSeconds: 1,
            volatilePreviewText: "",
            statusMessage: "音声トラックを準備しています...",
            finalizedSegments: nil
        ))

        let reader = try await MediaInspector.prepareAudioReader(for: url)
        let totalDuration = max(0.1, reader.durationSeconds)

        switch config.engine {
        case .speechTranscriber:
            return try await transcribeWithSpeechTranscriber(
                reader: reader,
                totalDuration: totalDuration,
                config: config,
                onProgress: onProgress
            )
        case .dictationTranscriber:
            return try await transcribeWithDictationTranscriber(
                reader: reader,
                totalDuration: totalDuration,
                config: config,
                onProgress: onProgress
            )
        case .sfSpeechRecognizer:
            return try await transcribeWithSFSpeechRecognizer(
                reader: reader,
                totalDuration: totalDuration,
                config: config,
                onProgress: onProgress
            )
        }
    }

    // MARK: - Engine 1: Apple SpeechTranscriber (SpeechAnalyzer)

    private static func transcribeWithSpeechTranscriber(
        reader: AudioSampleReader,
        totalDuration: Double,
        config: TranscriptionConfig,
        onProgress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> [TranscriptSegment] {
        let requestedLocale = Locale(identifier: config.localeIdentifier)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw SpeechServiceError.localeNotSupported(config.localeIdentifier)
        }

        var transcriptionOptions: Set<SpeechTranscriber.TranscriptionOption> = []
        if config.enableEtiquetteReplacements {
            transcriptionOptions.insert(.etiquetteReplacements)
        }

        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: transcriptionOptions,
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        try await ensureModelInstalled(module: transcriber, totalDuration: totalDuration, onProgress: onProgress)

        let analysisContext = AnalysisContext()
        if !config.contextualStrings.isEmpty {
            analysisContext.contextualStrings[.general] = config.contextualStrings
        }

        let analyzerOptions = SpeechAnalyzer.Options(
            priority: .userInitiated,
            modelRetention: .whileInUse
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        try await analyzer.setContext(analysisContext)

        let audioFile = try AVAudioFile(forReading: reader.audioFileURL)

        onProgress(TranscriptionProgressUpdate(
            processedSeconds: 0,
            totalSeconds: totalDuration,
            volatilePreviewText: "",
            statusMessage: "Apple SpeechTranscriber (オンデバイス) で音声認識中...",
            finalizedSegments: []
        ))

        let builder = UtteranceSegmentBuilder(
            pauseThreshold: config.pauseThresholdSeconds,
            maxSegmentDuration: config.maxSegmentDurationSeconds
        )

        let resultCollectorTask = Task<[TranscriptSegment], Error> {
            var currentSegments: [TranscriptSegment] = []
            var lastClusterCount = 0

            for try await result in transcriber.results {
                try Task.checkCancellation()

                let rangeEnd = max(0, CMTimeGetSeconds(result.range.end))
                let plainText = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)

                if result.isFinal {
                    let tokens = extractTokens(from: result.text, fallbackRange: result.range)
                    let newlyCommitted = builder.appendTokens(tokens)
                    if !newlyCommitted.isEmpty {
                        for var seg in newlyCommitted {
                            seg.index = currentSegments.count + 1
                            if let audioSlice = reader.readMonoSamples(startTime: seg.startTime, endTime: seg.endTime) {
                                seg.embedding = SpeakerDiarizer.extractEmbedding(
                                    samples: audioSlice.samples,
                                    sampleRate: audioSlice.sampleRate
                                )
                            }
                            currentSegments.append(seg)
                        }

                        // Run incremental speaker clustering periodically so live UI shows speaker tags
                        if config.speakerMode != .off && (currentSegments.count - lastClusterCount >= 3 || currentSegments.count <= 4) {
                            SpeakerDiarizer.assignSpeakers(segments: &currentSegments, mode: config.speakerMode)
                            lastClusterCount = currentSegments.count
                        }

                        onProgress(TranscriptionProgressUpdate(
                            processedSeconds: min(totalDuration, rangeEnd),
                            totalSeconds: totalDuration,
                            volatilePreviewText: builder.currentPendingPreview(),
                            statusMessage: "音声認識中 (\(TimeFormatter.format(min(totalDuration, rangeEnd), includeMillis: false)) / \(TimeFormatter.format(totalDuration, includeMillis: false)))",
                            finalizedSegments: currentSegments
                        ))
                    } else {
                        onProgress(TranscriptionProgressUpdate(
                            processedSeconds: min(totalDuration, rangeEnd),
                            totalSeconds: totalDuration,
                            volatilePreviewText: builder.currentPendingPreview(),
                            statusMessage: "音声認識中 (\(TimeFormatter.format(min(totalDuration, rangeEnd), includeMillis: false)) / \(TimeFormatter.format(totalDuration, includeMillis: false)))",
                            finalizedSegments: nil
                        ))
                    }
                } else if !plainText.isEmpty {
                    let combinedPreview = [builder.currentPendingPreview(), plainText]
                        .filter { !$0.isEmpty }
                        .joined(separator: "")
                    onProgress(TranscriptionProgressUpdate(
                        processedSeconds: min(totalDuration, max(0, CMTimeGetSeconds(result.range.start))),
                        totalSeconds: totalDuration,
                        volatilePreviewText: String(combinedPreview.suffix(120)),
                        statusMessage: "音声認識中...",
                        finalizedSegments: nil
                    ))
                }
            }

            // Flush any remaining buffered tokens at end of file
            let trailing = builder.flushRemaining()
            for var seg in trailing {
                seg.index = currentSegments.count + 1
                if let audioSlice = reader.readMonoSamples(startTime: seg.startTime, endTime: seg.endTime) {
                    seg.embedding = SpeakerDiarizer.extractEmbedding(
                        samples: audioSlice.samples,
                        sampleRate: audioSlice.sampleRate
                    )
                }
                currentSegments.append(seg)
            }

            // Final global speaker diarization refinement
            SpeakerDiarizer.assignSpeakers(segments: &currentSegments, mode: config.speakerMode)
            return currentSegments
        }

        do {
            if let lastTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let finalSegments = try await resultCollectorTask.value
            onProgress(TranscriptionProgressUpdate(
                processedSeconds: totalDuration,
                totalSeconds: totalDuration,
                volatilePreviewText: "",
                statusMessage: "完了 (\(finalSegments.count) セグメント)",
                finalizedSegments: finalSegments
            ))
            return finalSegments
        } catch {
            resultCollectorTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    // MARK: - Engine 2: Apple DictationTranscriber (SpeechAnalyzer)

    private static func transcribeWithDictationTranscriber(
        reader: AudioSampleReader,
        totalDuration: Double,
        config: TranscriptionConfig,
        onProgress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> [TranscriptSegment] {
        let requestedLocale = Locale(identifier: config.localeIdentifier)
        guard let supportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw SpeechServiceError.localeNotSupported(config.localeIdentifier)
        }

        var transcriptionOptions: Set<DictationTranscriber.TranscriptionOption> = [.punctuation]
        if config.enableEtiquetteReplacements {
            transcriptionOptions.insert(.etiquetteReplacements)
        }

        let transcriber = DictationTranscriber(
            locale: supportedLocale,
            contentHints: [.farField],
            transcriptionOptions: transcriptionOptions,
            reportingOptions: [.volatileResults, .frequentFinalization],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )

        try await ensureModelInstalled(module: transcriber, totalDuration: totalDuration, onProgress: onProgress)

        let analysisContext = AnalysisContext()
        if !config.contextualStrings.isEmpty {
            analysisContext.contextualStrings[.general] = config.contextualStrings
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.setContext(analysisContext)

        let audioFile = try AVAudioFile(forReading: reader.audioFileURL)

        onProgress(TranscriptionProgressUpdate(
            processedSeconds: 0,
            totalSeconds: totalDuration,
            volatilePreviewText: "",
            statusMessage: "Apple DictationTranscriber (オンデバイス) で音声認識中...",
            finalizedSegments: []
        ))

        let builder = UtteranceSegmentBuilder(
            pauseThreshold: config.pauseThresholdSeconds,
            maxSegmentDuration: config.maxSegmentDurationSeconds
        )

        let resultCollectorTask = Task<[TranscriptSegment], Error> {
            var currentSegments: [TranscriptSegment] = []

            for try await result in transcriber.results {
                try Task.checkCancellation()
                let rangeEnd = max(0, CMTimeGetSeconds(result.range.end))
                let plainText = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)

                if result.isFinal {
                    let tokens = extractTokens(from: result.text, fallbackRange: result.range)
                    let newlyCommitted = builder.appendTokens(tokens)
                    if !newlyCommitted.isEmpty {
                        for var seg in newlyCommitted {
                            seg.index = currentSegments.count + 1
                            if let audioSlice = reader.readMonoSamples(startTime: seg.startTime, endTime: seg.endTime) {
                                seg.embedding = SpeakerDiarizer.extractEmbedding(
                                    samples: audioSlice.samples,
                                    sampleRate: audioSlice.sampleRate
                                )
                            }
                            currentSegments.append(seg)
                        }
                        SpeakerDiarizer.assignSpeakers(segments: &currentSegments, mode: config.speakerMode)
                        onProgress(TranscriptionProgressUpdate(
                            processedSeconds: min(totalDuration, rangeEnd),
                            totalSeconds: totalDuration,
                            volatilePreviewText: builder.currentPendingPreview(),
                            statusMessage: "音声認識中 (\(TimeFormatter.format(min(totalDuration, rangeEnd), includeMillis: false)) / \(TimeFormatter.format(totalDuration, includeMillis: false)))",
                            finalizedSegments: currentSegments
                        ))
                    }
                } else if !plainText.isEmpty {
                    onProgress(TranscriptionProgressUpdate(
                        processedSeconds: min(totalDuration, max(0, CMTimeGetSeconds(result.range.start))),
                        totalSeconds: totalDuration,
                        volatilePreviewText: String(plainText.suffix(120)),
                        statusMessage: "Dictation認識中...",
                        finalizedSegments: nil
                    ))
                }
            }

            let trailing = builder.flushRemaining()
            for var seg in trailing {
                seg.index = currentSegments.count + 1
                if let audioSlice = reader.readMonoSamples(startTime: seg.startTime, endTime: seg.endTime) {
                    seg.embedding = SpeakerDiarizer.extractEmbedding(
                        samples: audioSlice.samples,
                        sampleRate: audioSlice.sampleRate
                    )
                }
                currentSegments.append(seg)
            }

            SpeakerDiarizer.assignSpeakers(segments: &currentSegments, mode: config.speakerMode)
            return currentSegments
        }

        do {
            if let lastTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastTime)
            } else {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            }
            let finalSegments = try await resultCollectorTask.value
            onProgress(TranscriptionProgressUpdate(
                processedSeconds: totalDuration,
                totalSeconds: totalDuration,
                volatilePreviewText: "",
                statusMessage: "完了 (\(finalSegments.count) セグメント)",
                finalizedSegments: finalSegments
            ))
            return finalSegments
        } catch {
            resultCollectorTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    // MARK: - Engine 3: Apple SFSpeechRecognizer (On-Device Chunked)

    private static func transcribeWithSFSpeechRecognizer(
        reader: AudioSampleReader,
        totalDuration: Double,
        config: TranscriptionConfig,
        onProgress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws -> [TranscriptSegment] {
        // Request Speech Recognition authorization if needed
        let authStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            throw SpeechServiceError.authorizationDenied
        }

        let locale = Locale(identifier: config.localeIdentifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechServiceError.recognizerUnavailable(config.localeIdentifier)
        }

        let builder = UtteranceSegmentBuilder(
            pauseThreshold: config.pauseThresholdSeconds,
            maxSegmentDuration: config.maxSegmentDurationSeconds
        )
        var allSegments: [TranscriptSegment] = []

        // Process in 45-second windows to avoid SFSpeechRecognizer's 60-second audio limit
        let chunkDuration = 45.0
        var chunkStart = 0.0

        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: reader.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechServiceError.recognizerUnavailable("PCMフォーマット初期化エラー")
        }

        while chunkStart < totalDuration {
            try Task.checkCancellation()
            let chunkEnd = min(totalDuration, chunkStart + chunkDuration)
            guard let slice = reader.readMonoSamples(
                startTime: chunkStart,
                endTime: chunkEnd,
                maxDuration: chunkDuration + 1.0
            ), !slice.samples.isEmpty else {
                chunkStart = chunkEnd
                continue
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if !config.contextualStrings.isEmpty {
                request.contextualStrings = config.contextualStrings
            }

            if let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(slice.samples.count)),
               let dst = pcmBuffer.floatChannelData?[0] {
                pcmBuffer.frameLength = AVAudioFrameCount(slice.samples.count)
                _ = slice.samples.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress!, slice.samples.count * MemoryLayout<Float>.size)
                }
                request.append(pcmBuffer)
            }
            request.endAudio()

            let offset = chunkStart
            let chunkTokens: [TranscriptToken] = try await withCheckedThrowingContinuation { continuation in
                var hasResumed = false
                let lock = NSLock()
                var latestTokens: [TranscriptToken] = []

                let task = recognizer.recognitionTask(with: request) { result, error in
                    lock.lock()
                    defer { lock.unlock() }
                    guard !hasResumed else { return }

                    if let result = result {
                        let partialText = result.bestTranscription.formattedString
                        latestTokens = result.bestTranscription.segments.map { seg in
                            TranscriptToken(
                                text: seg.substring,
                                startTime: offset + seg.timestamp,
                                endTime: offset + seg.timestamp + max(0.05, seg.duration),
                                confidence: Double(seg.confidence)
                            )
                        }

                        onProgress(TranscriptionProgressUpdate(
                            processedSeconds: min(totalDuration, offset + (result.bestTranscription.segments.last.map { $0.timestamp + $0.duration } ?? 0)),
                            totalSeconds: totalDuration,
                            volatilePreviewText: String(partialText.suffix(120)),
                            statusMessage: "SFSpeechRecognizer 認識中 (\(TimeFormatter.format(offset, includeMillis: false))〜)...",
                            finalizedSegments: nil
                        ))

                        if result.isFinal {
                            hasResumed = true
                            continuation.resume(returning: latestTokens)
                        }
                    } else if let error = error {
                        hasResumed = true
                        // If a chunk is silent, SFSpeechRecognizer may return "No speech detected"; treat as empty tokens
                        if !latestTokens.isEmpty {
                            continuation.resume(returning: latestTokens)
                        } else {
                            let nsErr = error as NSError
                            if nsErr.domain == "kAFAssistantErrorDomain" || nsErr.code == 1110 || nsErr.code == 203 {
                                continuation.resume(returning: [])
                            } else {
                                continuation.resume(throwing: error)
                            }
                        }
                    }
                }
                _ = task
            }

            let newlyCommitted = builder.appendTokens(chunkTokens)
            for var seg in newlyCommitted {
                seg.index = allSegments.count + 1
                if let audioSlice = reader.readMonoSamples(startTime: seg.startTime, endTime: seg.endTime) {
                    seg.embedding = SpeakerDiarizer.extractEmbedding(
                        samples: audioSlice.samples,
                        sampleRate: audioSlice.sampleRate
                    )
                }
                allSegments.append(seg)
            }

            SpeakerDiarizer.assignSpeakers(segments: &allSegments, mode: config.speakerMode)
            onProgress(TranscriptionProgressUpdate(
                processedSeconds: chunkEnd,
                totalSeconds: totalDuration,
                volatilePreviewText: builder.currentPendingPreview(),
                statusMessage: "SFSpeechRecognizer 認識中 (\(TimeFormatter.format(chunkEnd, includeMillis: false)) / \(TimeFormatter.format(totalDuration, includeMillis: false)))",
                finalizedSegments: allSegments
            ))

            chunkStart = chunkEnd
        }

        let trailing = builder.flushRemaining()
        for var seg in trailing {
            seg.index = allSegments.count + 1
            if let audioSlice = reader.readMonoSamples(startTime: seg.startTime, endTime: seg.endTime) {
                seg.embedding = SpeakerDiarizer.extractEmbedding(
                    samples: audioSlice.samples,
                    sampleRate: audioSlice.sampleRate
                )
            }
            allSegments.append(seg)
        }

        SpeakerDiarizer.assignSpeakers(segments: &allSegments, mode: config.speakerMode)
        onProgress(TranscriptionProgressUpdate(
            processedSeconds: totalDuration,
            totalSeconds: totalDuration,
            volatilePreviewText: "",
            statusMessage: "完了 (\(allSegments.count) セグメント)",
            finalizedSegments: allSegments
        ))

        return allSegments
    }

    // MARK: - Model Installation Helper

    private static func ensureModelInstalled(
        module: any SpeechModule,
        totalDuration: Double,
        onProgress: @escaping @Sendable (TranscriptionProgressUpdate) -> Void
    ) async throws {
        let status = await AssetInventory.status(forModules: [module])
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                onProgress(TranscriptionProgressUpdate(
                    processedSeconds: 0,
                    totalSeconds: totalDuration,
                    volatilePreviewText: "",
                    statusMessage: "Appleのオンデバイス音声認識モデルを準備・ダウンロードしています...",
                    finalizedSegments: nil
                ))
                try await request.downloadAndInstall()
            }
        case .unsupported:
            throw SpeechServiceError.recognizerUnavailable("この言語モデルは現在の環境でサポートされていません。")
        @unknown default:
            return
        }
    }

    // MARK: - AttributedString Token Extraction

    private static func extractTokens(
        from attributedText: AttributedString,
        fallbackRange: CMTimeRange
    ) -> [TranscriptToken] {
        var tokens: [TranscriptToken] = []
        let fallbackStart = max(0, CMTimeGetSeconds(fallbackRange.start))
        let fallbackEnd = max(fallbackStart + 0.05, CMTimeGetSeconds(fallbackRange.end))

        for run in attributedText.runs {
            let textPiece = String(attributedText[run.range].characters)
            guard !textPiece.isEmpty else { continue }

            let conf = run.transcriptionConfidence
            if let tr = run.audioTimeRange {
                let s = max(0, CMTimeGetSeconds(tr.start))
                let e = max(s + 0.02, CMTimeGetSeconds(tr.end))
                tokens.append(TranscriptToken(
                    text: textPiece,
                    startTime: s,
                    endTime: e,
                    confidence: (conf != nil && conf! >= 0) ? conf : nil
                ))
            } else {
                let prevEnd = tokens.last?.endTime ?? fallbackStart
                tokens.append(TranscriptToken(
                    text: textPiece,
                    startTime: prevEnd,
                    endTime: max(prevEnd + 0.02, fallbackEnd),
                    confidence: (conf != nil && conf! >= 0) ? conf : nil
                ))
            }
        }

        if tokens.isEmpty {
            let plain = String(attributedText.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                tokens.append(TranscriptToken(
                    text: plain,
                    startTime: fallbackStart,
                    endTime: fallbackEnd,
                    confidence: nil
                ))
            }
        }

        return tokens
    }
}

// MARK: - Utterance Segment Builder

/// Intelligently merges character/word-level tokens from Apple's SpeechTranscriber into natural utterance segments.
/// Prevents mid-word splits across acoustic window boundaries and trims leading/trailing silence.
final class UtteranceSegmentBuilder {
    private let pauseThreshold: Double
    private let maxSegmentDuration: Double
    private var pendingTokens: [TranscriptToken] = []

    private static let sentenceEndCharacters: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
    private static let clausePauseCharacters: Set<Character> = ["、", ",", "，"]

    init(pauseThreshold: Double = 0.45, maxSegmentDuration: Double = 14.0) {
        self.pauseThreshold = max(0.15, pauseThreshold)
        self.maxSegmentDuration = max(4.0, maxSegmentDuration)
    }

    func appendTokens(_ newTokens: [TranscriptToken]) -> [TranscriptSegment] {
        var committed: [TranscriptSegment] = []

        for token in newTokens {
            if let last = pendingTokens.last {
                let silenceGap = token.startTime - last.endTime
                let currentStart = pendingTokens.first!.startTime
                let currentDuration = token.endTime - currentStart
                let lastChar = last.text.trimmingCharacters(in: .whitespaces).last

                let isSentenceEnd = lastChar.map { Self.sentenceEndCharacters.contains($0) } ?? false
                let isClauseEnd = lastChar.map { Self.clausePauseCharacters.contains($0) } ?? false

                let shouldSplitBySilence = silenceGap >= pauseThreshold
                let shouldSplitBySentence = isSentenceEnd && currentDuration >= 0.6
                let shouldSplitByMaxDuration = currentDuration >= maxSegmentDuration && (isClauseEnd || silenceGap >= 0.12 || currentDuration >= maxSegmentDuration + 4.0)

                if shouldSplitBySilence || shouldSplitBySentence || shouldSplitByMaxDuration {
                    if let seg = buildSegment(from: pendingTokens) {
                        committed.append(seg)
                    }
                    pendingTokens.removeAll(keepingCapacity: true)
                }
            }

            pendingTokens.append(token)
        }

        // Also if the last pending token already ends with sentence-ending punctuation and is long enough, commit it immediately
        if let last = pendingTokens.last,
           let first = pendingTokens.first,
           let lastChar = last.text.trimmingCharacters(in: .whitespaces).last,
           Self.sentenceEndCharacters.contains(lastChar),
           (last.endTime - first.startTime) >= 0.8 {
            if let seg = buildSegment(from: pendingTokens) {
                committed.append(seg)
            }
            pendingTokens.removeAll(keepingCapacity: true)
        }

        return committed
    }

    func flushRemaining() -> [TranscriptSegment] {
        defer { pendingTokens.removeAll() }
        if let seg = buildSegment(from: pendingTokens) {
            return [seg]
        }
        return []
    }

    func currentPendingPreview() -> String {
        pendingTokens.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildSegment(from tokens: [TranscriptToken]) -> TranscriptSegment? {
        guard !tokens.isEmpty else { return nil }
        let combinedText = tokens.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combinedText.isEmpty else { return nil }

        let start = tokens.first!.startTime
        let end = max(start + 0.05, tokens.last!.endTime)

        let validConfs = tokens.compactMap { $0.confidence }
        let avgConf: Double? = validConfs.isEmpty ? nil : (validConfs.reduce(0, +) / Double(validConfs.count))

        return TranscriptSegment(
            index: 0,
            startTime: start,
            endTime: end,
            text: combinedText,
            speakerID: 1,
            confidence: avgConf,
            embedding: nil
        )
    }
}
