import Foundation
import AVFoundation
import Accelerate

// MARK: - Frame-Level Features

/// Frame-level acoustic features of a whole recording (16 kHz, 25 ms window, 10 ms hop).
/// Extracted once per file and kept so that speaker re-clustering never needs to re-read the audio.
struct DiarizationFeatures: Sendable {
    static let frameRate: Double = 100.0

    /// Number of cepstral coefficients per frame (c1...c19)
    let dim: Int
    /// Number of frames
    let count: Int
    /// Row-major `count * dim` MFCC matrix, globally mean/variance normalized
    let mfcc: [Float]
    /// Per-frame log energy (natural log of mean squared amplitude)
    let logEnergy: [Float]

    static func frameIndex(for seconds: Double) -> Int {
        Int((seconds * frameRate).rounded(.down))
    }
}

// MARK: - Frame-Level Speaker Diarization

/// Classic, fully local, training-free speaker diarization pipeline:
///  1. MFCC frames for the whole file (Accelerate vDSP FFT + Mel filterbank + DCT)
///  2. Universal background GMM (UBM) fitted on all speech frames of the recording
///  3. ~2 s speech chunks -> MAP-adapted GMM mean supervectors
///  4. Spectral clustering of the chunk cosine affinity (eigengap -> speaker count in auto mode)
///  5. Per-speaker MAP-adapted GMMs + Viterbi re-segmentation at 10 ms resolution (iterated)
///  6. Token-level voting: utterances are split where the speaker changes mid-utterance
enum DiarizationEngine {

    // MARK: Tunables

    private static let sampleRate: Double = 16_000
    private static let windowLength = 400          // 25 ms
    private static let hopLength = 160             // 10 ms
    private static let fftSize = 512
    private static let numMelBands = 40
    private static let numCepstra = 19             // c1...c19

    private static let ubmComponents = 32
    private static let mapRelevance: Float = 16
    private static let chunkFrames = 200          // 2.0 s of speech per clustering chunk
    private static let minChunkFrames = 70         // chunks shorter than this are not used for initial clustering
    private static let chunkBreakGapFrames = 30    // a pause > 0.3 s always starts a new chunk
    private static let maxAutoSpeakers = 6
    private static let maxClusteringChunks = 1800

    /// Speaker switch penalties (in scaled log-likelihood units) for the frame- and token-level Viterbi decoders:
    /// inside continuous speech, after a pause and (token level only) right after punctuation
    private static let switchPenaltyContinuous: Float = 15.0
    private static let switchPenaltyAfterPause: Float = 2.0
    private static let switchPenaltyAtPunctuation: Float = 3.0
    private static let pauseFramesForCheapSwitch = 15
    /// ASR token timestamps run ~0.1 s ahead of the audio
    private static let tokenTimeShift: Double = 0.1
    /// Frame log-likelihoods are strongly correlated; scale them down before Viterbi decoding
    private static let emissionScale: Float = 0.35
    private static let resegmentationIterations = 4

    // MARK: - 1. Feature Extraction

    static func extractFeatures(
        url: URL,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws -> DiarizationFeatures {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioExtractorError.readerCreationFailed
        }
        converter.downmix = true

        let inCapacity: AVAudioFrameCount = 32_768
        let outCapacity: AVAudioFrameCount = AVAudioFrameCount(Double(inCapacity) * sampleRate / max(1, inFormat.sampleRate)) + 1024
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw AudioExtractorError.readerCreationFailed
        }

        let extractor = MFCCFrameExtractor(
            sampleRate: Float(sampleRate),
            windowLength: windowLength,
            hopLength: hopLength,
            fftSize: fftSize,
            numMelBands: numMelBands,
            numCepstra: numCepstra
        )

        final class EOFBox { var reachedEnd = false }
        let eof = EOFBox()

        while true {
            if shouldCancel() { throw CancellationError() }
            var conversionError: NSError?
            outBuffer.frameLength = 0
            let status = converter.convert(to: outBuffer, error: &conversionError) { requested, outStatus in
                if eof.reachedEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuffer, frameCount: min(requested, inCapacity))
                } catch {
                    eof.reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuffer.frameLength == 0 {
                    eof.reachedEnd = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error {
                throw AudioExtractorError.exportFailed(conversionError?.localizedDescription ?? "サンプルレート変換エラー")
            }
            if outBuffer.frameLength > 0, let ch0 = outBuffer.floatChannelData?[0] {
                extractor.append(UnsafeBufferPointer(start: ch0, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || (status == .inputRanDry && eof.reachedEnd) {
                break
            }
        }

        return extractor.finish()
    }

    // MARK: - 2. Main Diarization Entry

    /// Assigns speaker IDs using frame-level features. Utterances whose tokens are attributed to
    /// different speakers are split at the change points. Returns re-indexed segments.
    static func diarize(
        segments: [TranscriptSegment],
        features: DiarizationFeatures,
        mode: SpeakerCountMode
    ) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }
        if mode == .off {
            return reindexed(segments.map { var s = $0; s.speakerID = 1; return s })
        }

        guard let fit = fitSpeakers(segments: segments, features: features, mode: mode), fit.k > 1 else {
            return reindexed(segments.map { var s = $0; s.speakerID = 1; return s })
        }

        // Token-level decoding: speaker changes are only allowed between ASR tokens and are cheap at
        // punctuation / pauses, expensive in the middle of continuous speech.
        let unitLabels = decodeTokens(segments: segments, fit: fit, frameCount: features.count)
        var output: [TranscriptSegment] = []
        for (si, seg) in segments.enumerated() {
            output.append(contentsOf: buildSegments(from: seg, unitLabels: unitLabels[si]))
        }

        // Canonicalize speaker numbers by order of first appearance
        var mapping: [Int: Int] = [:]
        var next = 1
        for i in output.indices {
            let raw = output[i].speakerID
            if mapping[raw] == nil {
                mapping[raw] = next
                next += 1
            }
            output[i].speakerID = mapping[raw] ?? 1
        }
        return reindexed(output)
    }

    private static func reindexed(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        var copy = segments
        for i in copy.indices { copy[i].index = i + 1 }
        return copy
    }

    /// Result of the acoustic speaker modelling stage.
    struct SpeakerFit {
        /// Number of speakers
        var k: Int
        /// Frame indices (into the file) that were treated as speech
        var speechFrames: [Int]
        /// Scaled per-speaker log-likelihoods, row-major `speechFrames.count * k`
        var scores: [Float]
        /// Viterbi frame labels (0...k-1) for `speechFrames`
        var labels: [Int]
    }

    /// Fits per-speaker GMMs and returns frame-level scores, or nil if there is too little speech.
    static func fitSpeakers(
        segments: [TranscriptSegment],
        features: DiarizationFeatures,
        mode: SpeakerCountMode
    ) -> SpeakerFit? {
        let n = features.count
        guard n > 0 else { return nil }

        // --- Speech activity: transcript token ranges ∩ energy above the noise floor
        var inTranscript = [Bool](repeating: false, count: n)
        for seg in segments {
            let ranges: [(Double, Double)] = (seg.tokens?.isEmpty == false)
                ? seg.tokens!.map { ($0.startTime - 0.04, $0.endTime + 0.04) }
                : [(seg.startTime, seg.endTime)]
            for (s, e) in ranges {
                let a = max(0, DiarizationFeatures.frameIndex(for: s))
                let b = min(n, DiarizationFeatures.frameIndex(for: e) + 1)
                if a < b { for t in a..<b { inTranscript[t] = true } }
            }
        }
        let sortedEnergy = features.logEnergy.sorted()
        let floor = percentile(sortedEnergy, 0.05)
        let loud = percentile(sortedEnergy, 0.95)
        let energyThreshold = floor + 0.28 * (loud - floor)

        var speechFrames: [Int] = []
        speechFrames.reserveCapacity(n / 2)
        for t in 0..<n where inTranscript[t] && features.logEnergy[t] > energyThreshold {
            speechFrames.append(t)
        }
        guard speechFrames.count >= 300 else { return nil }

        let dim = features.dim
        let X = gatherRows(features.mfcc, dim: dim, rows: speechFrames)
        let ns = speechFrames.count

        // --- UBM
        let ubm = DiagonalGMM.train(data: X, count: ns, dim: dim, components: ubmComponents, maxTrainFrames: 60_000)

        // --- Clustering chunks (contiguous speech, ≤ 2 s)
        var chunks: [Range<Int>] = []   // ranges into speechFrames
        var chunkStart = 0
        for i in 1...ns {
            let isEnd = i == ns
                || speechFrames[i] - speechFrames[i - 1] > chunkBreakGapFrames
                || i - chunkStart >= chunkFrames
            if isEnd {
                chunks.append(chunkStart..<i)
                chunkStart = i
            }
        }
        var clusterChunks = chunks.filter { $0.count >= minChunkFrames }
        guard clusterChunks.count >= 4 else { return nil }
        // Spectral clustering is O(n³): for very long recordings cluster an even subsample of chunks.
        // The remaining frames start unlabeled and are assigned by the Viterbi re-segmentation.
        if clusterChunks.count > maxClusteringChunks {
            let step = Double(clusterChunks.count) / Double(maxClusteringChunks)
            clusterChunks = (0..<maxClusteringChunks).map { clusterChunks[Int(Double($0) * step)] }
        }

        // --- Supervectors via UBM posteriors
        let posteriors = ubm.posteriors(data: X, count: ns)   // ns * M
        let M = ubm.components
        let svDim = M * dim
        var supervectors = [Float](repeating: 0, count: clusterChunks.count * svDim)
        for (ci, range) in clusterChunks.enumerated() {
            var zeroth = [Float](repeating: 0, count: M)
            var first = [Float](repeating: 0, count: M * dim)
            for r in range {
                let post = r * M
                let row = r * dim
                for m in 0..<M {
                    let g = posteriors[post + m]
                    if g < 1e-4 { continue }
                    zeroth[m] += g
                    let fm = m * dim
                    for d in 0..<dim { first[fm + d] += g * X[row + d] }
                }
            }
            let base = ci * svDim
            for m in 0..<M {
                let scale = sqrtf(ubm.weights[m]) / (zeroth[m] + mapRelevance)
                for d in 0..<dim {
                    let idx = m * dim + d
                    let centered = first[idx] - zeroth[m] * ubm.means[idx]
                    supervectors[base + idx] = scale * centered / sqrtf(ubm.variances[idx])
                }
            }
        }
        centerAndNormalizeRows(&supervectors, rows: clusterChunks.count, cols: svDim)

        // --- Spectral clustering
        let fixedK: Int? = mode == .auto ? nil : max(1, mode.rawValue)
        let chunkLabels = SpectralClusterer.cluster(
            vectors: supervectors,
            rows: clusterChunks.count,
            cols: svDim,
            fixedK: fixedK,
            maxK: maxAutoSpeakers
        )
        var k = (chunkLabels.max() ?? 0) + 1
        if k <= 1 {
            return SpeakerFit(k: 1, speechFrames: speechFrames, scores: [Float](repeating: 0, count: ns), labels: [Int](repeating: 0, count: ns))
        }

        // --- Initial speech-frame labels from chunks (unclustered short chunks: -1)
        var speechLabels = [Int](repeating: -1, count: ns)
        for (ci, range) in clusterChunks.enumerated() {
            for r in range { speechLabels[r] = chunkLabels[ci] }
        }

        // --- Iterative GMM re-estimation + Viterbi re-segmentation
        func speakerScores(labels: [Int], k: Int) -> [Float] {
            var buckets = [[Int]](repeating: [], count: k)
            for (i, l) in labels.enumerated() where l >= 0 && l < k { buckets[l].append(i) }
            var scores = [Float](repeating: 0, count: ns * k)
            for c in 0..<k {
                let model = ubm.mapAdaptedMeans(data: X, posteriors: posteriors, frames: buckets[c], relevance: mapRelevance)
                let ll = model.frameLogLikelihoods(data: X, count: ns)
                for i in 0..<ns { scores[i * k + c] = ll[i] * emissionScale }
            }
            return scores
        }

        for _ in 0..<resegmentationIterations {
            let scores = speakerScores(labels: speechLabels, k: k)
            var newLabels = viterbi(scores: scores, count: ns, states: k, frameIndices: speechFrames)

            // Drop speakers that ended up with almost no speech, then re-number densely
            var counts = [Int](repeating: 0, count: k)
            for l in newLabels { counts[l] += 1 }
            let minFrames = max(150, ns / 100)
            let keep = (0..<k).filter { counts[$0] >= minFrames }
            if keep.count < k && !keep.isEmpty {
                if keep.count == 1 {
                    return SpeakerFit(k: 1, speechFrames: speechFrames, scores: [Float](repeating: 0, count: ns), labels: [Int](repeating: 0, count: ns))
                }
                var remap = [Int: Int]()
                for (newIdx, old) in keep.enumerated() { remap[old] = newIdx }
                for i in newLabels.indices { newLabels[i] = remap[newLabels[i]] ?? -1 }
                k = keep.count
            }
            let changed = zip(newLabels, speechLabels).filter { $0 != $1 }.count
            speechLabels = newLabels
            if changed < ns / 500 { break }
        }

        let finalScores = speakerScores(labels: speechLabels, k: k)
        return SpeakerFit(k: k, speechFrames: speechFrames, scores: finalScores, labels: speechLabels)
    }

    // MARK: - Viterbi Re-Segmentation

    private static func viterbi(scores: [Float], count: Int, states k: Int, frameIndices: [Int]) -> [Int] {
        guard count > 0 else { return [] }
        var delta = [Float](repeating: 0, count: k)
        var backPointers = [Int32](repeating: 0, count: count * k)
        for c in 0..<k { delta[c] = scores[c] }

        var nextDelta = [Float](repeating: 0, count: k)
        for i in 1..<max(1, count) {
            let gap = frameIndices[i] - frameIndices[i - 1]
            let penalty = gap >= pauseFramesForCheapSwitch ? switchPenaltyAfterPause : switchPenaltyContinuous
            var bestPrev = 0
            var bestVal = delta[0]
            for c in 1..<k where delta[c] > bestVal {
                bestVal = delta[c]
                bestPrev = c
            }
            for c in 0..<k {
                let stay = delta[c]
                let switchVal = bestPrev == c ? -Float.greatestFiniteMagnitude : bestVal - penalty
                if stay >= switchVal {
                    nextDelta[c] = stay + scores[i * k + c]
                    backPointers[i * k + c] = Int32(c)
                } else {
                    nextDelta[c] = switchVal + scores[i * k + c]
                    backPointers[i * k + c] = Int32(bestPrev)
                }
            }
            // keep numbers bounded
            let mx = nextDelta.max() ?? 0
            for c in 0..<k { delta[c] = nextDelta[c] - mx }
        }

        var labels = [Int](repeating: 0, count: count)
        var state = delta.indices.max(by: { delta[$0] < delta[$1] }) ?? 0
        for i in stride(from: count - 1, through: 0, by: -1) {
            labels[i] = state
            state = Int(backPointers[i * k + state])
        }
        return labels
    }

    // MARK: - Token-Level Decoding & Segment Splitting

    /// Time units of a segment used for decoding: its tokens, or the whole segment when tokens are unavailable.
    private static func units(of seg: TranscriptSegment) -> [TranscriptToken] {
        if let tokens = seg.tokens, !tokens.isEmpty { return tokens }
        return [TranscriptToken(text: seg.text, startTime: seg.startTime, endTime: seg.endTime, confidence: seg.confidence)]
    }

    /// Viterbi decoding over all tokens of the transcript. Returns per-segment, per-unit speaker labels.
    private static func decodeTokens(segments: [TranscriptSegment], fit: SpeakerFit, frameCount n: Int) -> [[Int]] {
        let k = fit.k
        // Dense per-frame score lookup (0 for non-speech frames)
        var frameScores = [Float](repeating: 0, count: n * k)
        for (i, t) in fit.speechFrames.enumerated() {
            for c in 0..<k { frameScores[t * k + c] = fit.scores[i * k + c] }
        }

        struct Unit { var emission: [Float]; var penalty: Float }
        var flat: [Unit] = []
        var counts: [Int] = []
        var previousEnd: Double = -1
        var previousText = ""
        for seg in segments {
            let toks = units(of: seg)
            counts.append(toks.count)
            for (j, tok) in toks.enumerated() {
                let a = max(0, min(n, DiarizationFeatures.frameIndex(for: tok.startTime + tokenTimeShift)))
                let b = max(a, min(n, DiarizationFeatures.frameIndex(for: tok.endTime + tokenTimeShift)))
                var e = [Float](repeating: 0, count: k)
                if b > a {
                    // Mean-centred so that frames do not favour any speaker on average
                    for t in a..<b {
                        var mean: Float = 0
                        for c in 0..<k { mean += frameScores[t * k + c] }
                        mean /= Float(k)
                        for c in 0..<k { e[c] += frameScores[t * k + c] - mean }
                    }
                }
                let gap = tok.startTime - previousEnd
                let lastChar = previousText.trimmingCharacters(in: .whitespaces).last
                var penalty = switchPenaltyContinuous
                if previousEnd < 0 {
                    penalty = 0
                } else if j == 0 || gap >= Double(pauseFramesForCheapSwitch) / DiarizationFeatures.frameRate {
                    penalty = switchPenaltyAfterPause
                } else if let ch = lastChar, "。、？！?!,.，".contains(ch) {
                    penalty = switchPenaltyAtPunctuation
                } else if gap >= 0.08 {
                    penalty = (switchPenaltyAfterPause + switchPenaltyContinuous) / 2
                }
                flat.append(Unit(emission: e, penalty: penalty))
                previousEnd = tok.endTime
                previousText = tok.text
            }
        }

        // Viterbi
        let m = flat.count
        guard m > 0 else { return counts.map { [Int](repeating: 0, count: $0) } }
        var delta = flat[0].emission
        var back = [Int32](repeating: 0, count: m * k)
        var next = [Float](repeating: 0, count: k)
        for i in 1..<max(1, m) {
            let pen = flat[i].penalty
            var bestPrev = 0
            for c in 1..<k where delta[c] > delta[bestPrev] { bestPrev = c }
            for c in 0..<k {
                let stay = delta[c]
                let sw = c == bestPrev ? -Float.greatestFiniteMagnitude : delta[bestPrev] - pen
                if stay >= sw {
                    next[c] = stay + flat[i].emission[c]
                    back[i * k + c] = Int32(c)
                } else {
                    next[c] = sw + flat[i].emission[c]
                    back[i * k + c] = Int32(bestPrev)
                }
            }
            let mx = next.max() ?? 0
            for c in 0..<k { delta[c] = next[c] - mx }
        }
        var labels = [Int](repeating: 0, count: m)
        var state = delta.indices.max(by: { delta[$0] < delta[$1] }) ?? 0
        for i in stride(from: m - 1, through: 0, by: -1) {
            labels[i] = state
            state = Int(back[i * k + state])
        }

        var result: [[Int]] = []
        var offset = 0
        for c in counts {
            result.append(Array(labels[offset..<(offset + c)]))
            offset += c
        }
        return result
    }

    /// Splits a segment into runs of tokens that share the same decoded speaker.
    private static func buildSegments(from seg: TranscriptSegment, unitLabels: [Int]) -> [TranscriptSegment] {
        guard let tokens = seg.tokens, tokens.count == unitLabels.count, tokens.count >= 2 else {
            var copy = seg
            copy.speakerID = unitLabels.first ?? 0
            return [copy]
        }
        var runs: [(start: Int, end: Int, label: Int)] = []
        for (i, l) in unitLabels.enumerated() {
            if let last = runs.last, last.label == l {
                runs[runs.count - 1].end = i + 1
            } else {
                runs.append((i, i + 1, l))
            }
        }
        if runs.count == 1 {
            var copy = seg
            copy.speakerID = runs[0].label
            return [copy]
        }
        return runs.map { r in
            let toks = Array(tokens[r.start..<r.end])
            let confs = toks.compactMap(\.confidence)
            return TranscriptSegment(
                index: 0,
                startTime: toks.first!.startTime,
                endTime: max(toks.first!.startTime + 0.05, toks.last!.endTime),
                text: toks.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                speakerID: r.label,
                confidence: confs.isEmpty ? nil : confs.reduce(0, +) / Double(confs.count),
                embedding: seg.embedding,
                tokens: toks
            )
        }
    }

    // MARK: - Small Helpers

    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }

    private static func gatherRows(_ matrix: [Float], dim: Int, rows: [Int]) -> [Float] {
        var out = [Float](repeating: 0, count: rows.count * dim)
        matrix.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for (i, r) in rows.enumerated() {
                    for d in 0..<dim { dst[i * dim + d] = src[r * dim + d] }
                }
            }
        }
        return out
    }

    private static func centerAndNormalizeRows(_ m: inout [Float], rows: Int, cols: Int) {
        var mean = [Float](repeating: 0, count: cols)
        for r in 0..<rows {
            for c in 0..<cols { mean[c] += m[r * cols + c] }
        }
        let inv = 1 / Float(max(1, rows))
        for c in 0..<cols { mean[c] *= inv }
        for r in 0..<rows {
            var norm: Float = 0
            for c in 0..<cols {
                let v = m[r * cols + c] - mean[c]
                m[r * cols + c] = v
                norm += v * v
            }
            let s = 1 / max(1e-6, sqrtf(norm))
            for c in 0..<cols { m[r * cols + c] *= s }
        }
    }
}

// MARK: - Streaming MFCC Extractor

private final class MFCCFrameExtractor {
    private let windowLength: Int
    private let hopLength: Int
    private let fftSize: Int
    private let numMelBands: Int
    private let numCepstra: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private let melFilters: [(start: Int, weights: [Float])]
    private let dct: [Float]   // numCepstra * numMelBands (c1...cN)

    /// Raw (not pre-emphasized) samples not yet consumed, and the sample preceding `pending[0]`
    private var pending: [Float] = []
    private var previousSample: Float = 0
    private var mfcc: [Float] = []
    private var logEnergy: [Float] = []

    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var power: [Float]
    private var logMel: [Float]

    init(sampleRate: Float, windowLength: Int, hopLength: Int, fftSize: Int, numMelBands: Int, numCepstra: Int) {
        self.windowLength = windowLength
        self.hopLength = hopLength
        self.fftSize = fftSize
        self.numMelBands = numMelBands
        self.numCepstra = numCepstra
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        var w = [Float](repeating: 0, count: windowLength)
        vDSP_hamm_window(&w, vDSP_Length(windowLength), 0)
        self.window = w

        // Triangular Mel filters (64 Hz ... 7600 Hz), stored sparsely
        func hzToMel(_ hz: Float) -> Float { 2595 * log10f(1 + hz / 700) }
        func melToHz(_ mel: Float) -> Float { 700 * (powf(10, mel / 2595) - 1) }
        let bins = fftSize / 2 + 1
        let lowMel = hzToMel(64), highMel = hzToMel(min(7600, sampleRate * 0.475))
        let points = (0..<(numMelBands + 2)).map { i -> Float in
            melToHz(lowMel + (highMel - lowMel) * Float(i) / Float(numMelBands + 1)) * Float(fftSize) / sampleRate
        }
        var filters: [(Int, [Float])] = []
        for m in 1...numMelBands {
            let l = points[m - 1], c = points[m], r = points[m + 1]
            let start = max(0, Int(ceil(l)))
            let end = min(bins - 1, Int(floor(r)))
            var weights: [Float] = []
            if end >= start {
                for b in start...end {
                    let x = Float(b)
                    let v = x <= c ? (x - l) / max(1e-3, c - l) : (r - x) / max(1e-3, r - c)
                    weights.append(max(0, v))
                }
            }
            filters.append((start, weights))
        }
        self.melFilters = filters

        var dctM = [Float](repeating: 0, count: numCepstra * numMelBands)
        let scale = sqrtf(2 / Float(numMelBands))
        for c in 1...numCepstra {
            for m in 0..<numMelBands {
                dctM[(c - 1) * numMelBands + m] = scale * cosf(Float.pi * Float(c) * (Float(m) + 0.5) / Float(numMelBands))
            }
        }
        self.dct = dctM

        frame = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        power = [Float](repeating: 0, count: fftSize / 2 + 1)
        logMel = [Float](repeating: 0, count: numMelBands)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func append(_ samples: UnsafeBufferPointer<Float>) {
        pending.append(contentsOf: samples)
        var pos = 0
        while pos + windowLength <= pending.count {
            processFrame(at: pos)
            pos += hopLength
        }
        if pos > 0 {
            previousSample = pending[pos - 1]
            pending.removeFirst(min(pos, pending.count))
        }
    }

    func finish() -> DiarizationFeatures {
        let count = logEnergy.count
        let dim = numCepstra
        guard count > 0 else {
            return DiarizationFeatures(dim: dim, count: 0, mfcc: [], logEnergy: [])
        }
        // Global mean/variance normalization (computed on the louder half of frames to ignore silence)
        let sortedE = logEnergy.sorted()
        let median = sortedE[count / 2]
        var mean = [Double](repeating: 0, count: dim)
        var sq = [Double](repeating: 0, count: dim)
        var used = 0
        for t in 0..<count where logEnergy[t] >= median {
            used += 1
            for d in 0..<dim {
                let v = Double(mfcc[t * dim + d])
                mean[d] += v
                sq[d] += v * v
            }
        }
        let inv = 1.0 / Double(max(1, used))
        var meanF = [Float](repeating: 0, count: dim)
        var invStd = [Float](repeating: 1, count: dim)
        for d in 0..<dim {
            let m = mean[d] * inv
            let v = max(1e-6, sq[d] * inv - m * m)
            meanF[d] = Float(m)
            invStd[d] = Float(1 / sqrt(v))
        }
        mfcc.withUnsafeMutableBufferPointer { buf in
            for t in 0..<count {
                for d in 0..<dim {
                    buf[t * dim + d] = (buf[t * dim + d] - meanF[d]) * invStd[d]
                }
            }
        }
        return DiarizationFeatures(dim: dim, count: count, mfcc: mfcc, logEnergy: logEnergy)
    }

    private func processFrame(at pos: Int) {
        let half = fftSize / 2
        var energy: Float = 0
        pending.withUnsafeBufferPointer { src in
            frame.withUnsafeMutableBufferPointer { dst in
                // pre-emphasized, windowed frame, zero padded to fftSize
                var prev = pos > 0 ? src[pos - 1] : previousSample
                var sumSq: Float = 0
                for i in 0..<windowLength {
                    let x = src[pos + i]
                    let emphasized = x - 0.97 * prev
                    sumSq += emphasized * emphasized
                    dst[i] = emphasized * window[i]
                    prev = x
                }
                energy = sumSq / Float(windowLength)
                for i in windowLength..<fftSize { dst[i] = 0 }
            }
        }

        logEnergy.append(logf(max(1e-10, energy)))

        real.withUnsafeMutableBufferPointer { rBuf in
            imag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // packed format: imag[0] holds Nyquist
                power[0] = rBuf[0] * rBuf[0]
                power[half] = iBuf[0] * iBuf[0]
                for b in 1..<half {
                    power[b] = rBuf[b] * rBuf[b] + iBuf[b] * iBuf[b]
                }
            }
        }

        for (m, filter) in melFilters.enumerated() {
            var e: Float = 0
            for (j, w) in filter.weights.enumerated() {
                e += w * power[filter.start + j]
            }
            logMel[m] = logf(max(1e-10, e))
        }
        for c in 0..<numCepstra {
            var v: Float = 0
            let base = c * numMelBands
            for m in 0..<numMelBands { v += dct[base + m] * logMel[m] }
            mfcc.append(v)
        }
    }
}

// MARK: - Diagonal-Covariance GMM

struct DiagonalGMM {
    let components: Int
    let dim: Int
    var weights: [Float]     // M
    var means: [Float]       // M * dim
    var variances: [Float]   // M * dim

    private static let varianceFloor: Float = 0.02

    /// Fits a GMM with k-means initialization followed by EM.
    static func train(data: [Float], count: Int, dim: Int, components requested: Int, maxTrainFrames: Int) -> DiagonalGMM {
        // Even subsampling for speed & determinism
        let step = max(1, count / maxTrainFrames)
        var sub: [Float] = []
        sub.reserveCapacity((count / step + 1) * dim)
        var i = 0
        while i < count {
            sub.append(contentsOf: data[(i * dim)..<((i + 1) * dim)])
            i += step
        }
        let n = sub.count / dim
        let M = max(1, min(requested, n / 20))

        // k-means init: centres spread evenly through time
        var means = [Float](repeating: 0, count: M * dim)
        for m in 0..<M {
            let r = (m * n) / M + (n / (2 * M))
            for d in 0..<dim { means[m * dim + d] = sub[min(n - 1, r) * dim + d] }
        }
        var assign = [Int](repeating: 0, count: n)
        for _ in 0..<10 {
            for t in 0..<n {
                var best = 0
                var bestD = Float.greatestFiniteMagnitude
                for m in 0..<M {
                    var dsum: Float = 0
                    for d in 0..<dim {
                        let diff = sub[t * dim + d] - means[m * dim + d]
                        dsum += diff * diff
                    }
                    if dsum < bestD { bestD = dsum; best = m }
                }
                assign[t] = best
            }
            var sums = [Float](repeating: 0, count: M * dim)
            var cnt = [Int](repeating: 0, count: M)
            for t in 0..<n {
                let m = assign[t]
                cnt[m] += 1
                for d in 0..<dim { sums[m * dim + d] += sub[t * dim + d] }
            }
            for m in 0..<M where cnt[m] > 0 {
                for d in 0..<dim { means[m * dim + d] = sums[m * dim + d] / Float(cnt[m]) }
            }
        }

        var gmm = DiagonalGMM(
            components: M,
            dim: dim,
            weights: [Float](repeating: 1 / Float(M), count: M),
            means: means,
            variances: [Float](repeating: 1, count: M * dim)
        )

        // EM
        for _ in 0..<12 {
            let post = gmm.posteriors(data: sub, count: n)
            var nk = [Float](repeating: 0, count: M)
            var f = [Float](repeating: 0, count: M * dim)
            var s = [Float](repeating: 0, count: M * dim)
            for t in 0..<n {
                for m in 0..<M {
                    let g = post[t * M + m]
                    if g < 1e-5 { continue }
                    nk[m] += g
                    for d in 0..<dim {
                        let x = sub[t * dim + d]
                        f[m * dim + d] += g * x
                        s[m * dim + d] += g * x * x
                    }
                }
            }
            for m in 0..<M {
                guard nk[m] > 1e-3 else { continue }
                gmm.weights[m] = max(1e-5, nk[m] / Float(n))
                for d in 0..<dim {
                    let mu = f[m * dim + d] / nk[m]
                    gmm.means[m * dim + d] = mu
                    gmm.variances[m * dim + d] = max(varianceFloor, s[m * dim + d] / nk[m] - mu * mu)
                }
            }
            let wsum = gmm.weights.reduce(0, +)
            for m in 0..<M { gmm.weights[m] /= wsum }
        }
        return gmm
    }

    /// Per-frame, per-component log(w_m) + log N(x | μ_m, Σ_m). Row-major `count * M`.
    func frameLogLikelihoodsPerComponent(data: [Float], count: Int) -> [Float] {
        let M = components
        // ll[t,m] = c_m + Σ_d x² (-0.5/σ²) + Σ_d x (μ/σ²)
        var negHalfPrecT = [Float](repeating: 0, count: dim * M)   // dim × M
        var meanPrecT = [Float](repeating: 0, count: dim * M)      // dim × M
        var consts = [Float](repeating: 0, count: M)
        let log2pi = logf(2 * Float.pi)
        for m in 0..<M {
            var c = logf(max(1e-10, weights[m])) - 0.5 * Float(dim) * log2pi
            for d in 0..<dim {
                let v = variances[m * dim + d]
                let mu = means[m * dim + d]
                negHalfPrecT[d * M + m] = -0.5 / v
                meanPrecT[d * M + m] = mu / v
                c -= 0.5 * (logf(v) + mu * mu / v)
            }
            consts[m] = c
        }

        var out = [Float](repeating: 0, count: count * M)
        let block = 4096
        var squared = [Float](repeating: 0, count: block * dim)
        var tmp = [Float](repeating: 0, count: block * M)
        data.withUnsafeBufferPointer { x in
            out.withUnsafeMutableBufferPointer { o in
                var start = 0
                while start < count {
                    let rows = min(block, count - start)
                    let xPtr = x.baseAddress! + start * dim
                    let oPtr = o.baseAddress! + start * M
                    vDSP_vsq(xPtr, 1, &squared, 1, vDSP_Length(rows * dim))
                    vDSP_mmul(squared, 1, negHalfPrecT, 1, oPtr, 1, vDSP_Length(rows), vDSP_Length(M), vDSP_Length(dim))
                    vDSP_mmul(xPtr, 1, meanPrecT, 1, &tmp, 1, vDSP_Length(rows), vDSP_Length(M), vDSP_Length(dim))
                    vDSP_vadd(oPtr, 1, tmp, 1, oPtr, 1, vDSP_Length(rows * M))
                    for r in 0..<rows {
                        vDSP_vadd(oPtr + r * M, 1, consts, 1, oPtr + r * M, 1, vDSP_Length(M))
                    }
                    start += rows
                }
            }
        }
        return out
    }

    /// Per-frame total log-likelihood log Σ_m w_m N(x | m).
    func frameLogLikelihoods(data: [Float], count: Int) -> [Float] {
        let comp = frameLogLikelihoodsPerComponent(data: data, count: count)
        let M = components
        var out = [Float](repeating: 0, count: count)
        comp.withUnsafeBufferPointer { c in
            for t in 0..<count {
                let row = c.baseAddress! + t * M
                var mx: Float = -.greatestFiniteMagnitude
                vDSP_maxv(row, 1, &mx, vDSP_Length(M))
                var s: Float = 0
                for m in 0..<M { s += expf(row[m] - mx) }
                out[t] = mx + logf(s)
            }
        }
        return out
    }

    /// Component posteriors γ[t,m]. Row-major `count * M`.
    func posteriors(data: [Float], count: Int) -> [Float] {
        var comp = frameLogLikelihoodsPerComponent(data: data, count: count)
        let M = components
        comp.withUnsafeMutableBufferPointer { c in
            for t in 0..<count {
                let row = c.baseAddress! + t * M
                var mx: Float = -.greatestFiniteMagnitude
                vDSP_maxv(row, 1, &mx, vDSP_Length(M))
                var s: Float = 0
                for m in 0..<M {
                    let e = expf(row[m] - mx)
                    row[m] = e
                    s += e
                }
                let inv = 1 / s
                for m in 0..<M { row[m] *= inv }
            }
        }
        return comp
    }

    /// Returns a copy of this (UBM) model whose means are MAP-adapted towards the given frames.
    func mapAdaptedMeans(data: [Float], posteriors: [Float], frames: [Int], relevance: Float) -> DiagonalGMM {
        let M = components
        var nk = [Float](repeating: 0, count: M)
        var f = [Float](repeating: 0, count: M * dim)
        for t in frames {
            for m in 0..<M {
                let g = posteriors[t * M + m]
                if g < 1e-4 { continue }
                nk[m] += g
                for d in 0..<dim { f[m * dim + d] += g * data[t * dim + d] }
            }
        }
        var adapted = self
        for m in 0..<M {
            let alpha = nk[m] / (nk[m] + relevance)
            guard nk[m] > 1e-4 else { continue }
            for d in 0..<dim {
                let idx = m * dim + d
                adapted.means[idx] = alpha * (f[idx] / nk[m]) + (1 - alpha) * means[idx]
            }
        }
        return adapted
    }
}

// MARK: - Spectral Clustering

enum SpectralClusterer {
    /// Clusters L2-normalized row vectors. Uses a pruned cosine affinity graph, a normalized Laplacian
    /// eigen-decomposition and k-means on the spectral embedding. `fixedK == nil` -> eigengap estimation.
    static func cluster(vectors: [Float], rows n: Int, cols: Int, fixedK: Int?, maxK: Int) -> [Int] {
        guard n >= 4 else { return [Int](repeating: 0, count: n) }

        // Cosine similarity S = V Vᵀ
        var vt = [Float](repeating: 0, count: cols * n)
        vDSP_mtrans(vectors, 1, &vt, 1, vDSP_Length(cols), vDSP_Length(n))
        var sim = [Float](repeating: 0, count: n * n)
        vDSP_mmul(vectors, 1, vt, 1, &sim, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(cols))

        // Row-wise pruning: keep the top p neighbours of every row, then symmetrize
        let p = max(4, min(n - 1, Int(Double(n) * 0.12)))
        var affinity = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            var idx = Array(0..<n)
            idx.remove(at: i)
            idx.sort { sim[i * n + $0] > sim[i * n + $1] }
            for j in idx.prefix(p) { affinity[i * n + j] = 1 }
        }
        for i in 0..<n {
            for j in (i + 1)..<n {
                let v = 0.5 * (affinity[i * n + j] + affinity[j * n + i])
                affinity[i * n + j] = v
                affinity[j * n + i] = v
            }
        }

        // Normalized Laplacian L = I - D^-1/2 A D^-1/2
        var degree = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            for j in 0..<n { s += affinity[i * n + j] }
            degree[i] = 1 / sqrtf(max(1e-6, s))
        }
        var laplacian = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n {
                let a = affinity[i * n + j] * degree[i] * degree[j]
                laplacian[i * n + j] = (i == j ? 1 : 0) - a
            }
        }

        guard let (eigenvalues, eigenvectors) = symmetricEigen(laplacian, n: n) else {
            return [Int](repeating: 0, count: n)
        }

        let k: Int
        if let fixed = fixedK {
            k = max(1, min(fixed, n - 1))
        } else {
            let limit = min(maxK, n - 2)
            var bestGap: Float = -1
            var bestK = 1
            for c in 1...max(1, limit) {
                let gap = eigenvalues[c] - eigenvalues[c - 1]
                if gap > bestGap {
                    bestGap = gap
                    bestK = c
                }
            }
            k = bestK
        }
        guard k > 1 else { return [Int](repeating: 0, count: n) }

        // Spectral embedding: first k eigenvectors (column-major from LAPACK), row-normalized
        var embedding = [Float](repeating: 0, count: n * k)
        for i in 0..<n {
            var norm: Float = 0
            for c in 0..<k {
                let v = eigenvectors[c * n + i]
                embedding[i * k + c] = v
                norm += v * v
            }
            let s = 1 / max(1e-6, sqrtf(norm))
            for c in 0..<k { embedding[i * k + c] *= s }
        }
        return kMeans(embedding, rows: n, cols: k, k: k)
    }

    /// Eigen-decomposition of a symmetric matrix (ascending eigenvalues, column-major eigenvectors).
    private static func symmetricEigen(_ matrix: [Float], n: Int) -> ([Float], [Float])? {
        var a = matrix  // symmetric: row-major == column-major
        var jobz = Int8(UInt8(ascii: "V"))
        var uplo = Int8(UInt8(ascii: "U"))
        var nn = __CLPK_integer(n)
        var lda = __CLPK_integer(n)
        var w = [Float](repeating: 0, count: n)
        var info: __CLPK_integer = 0
        var lworkQuery: __CLPK_integer = -1
        var liworkQuery: __CLPK_integer = -1
        var workSize: Float = 0
        var iworkSize: __CLPK_integer = 0
        ssyevd_(&jobz, &uplo, &nn, &a, &lda, &w, &workSize, &lworkQuery, &iworkSize, &liworkQuery, &info)
        guard info == 0 else { return nil }
        var lwork = __CLPK_integer(workSize)
        var liwork = iworkSize
        var work = [Float](repeating: 0, count: Int(lwork))
        var iwork = [__CLPK_integer](repeating: 0, count: Int(liwork))
        ssyevd_(&jobz, &uplo, &nn, &a, &lda, &w, &work, &lwork, &iwork, &liwork, &info)
        guard info == 0 else { return nil }
        return (w, a)
    }

    static func kMeans(_ x: [Float], rows n: Int, cols d: Int, k: Int) -> [Int] {
        var bestLabels = [Int](repeating: 0, count: n)
        var bestInertia = Float.greatestFiniteMagnitude
        for restart in 0..<8 {
            // farthest-first initialization from a different seed point each restart
            var centers: [[Float]] = [Array(x[((restart * n / 8) % n) * d..<(((restart * n / 8) % n) + 1) * d])]
            var minDist = [Float](repeating: .greatestFiniteMagnitude, count: n)
            while centers.count < k {
                var far = 0
                var farD: Float = -1
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<d { let v = x[i * d + c] - centers.last![c]; s += v * v }
                    minDist[i] = min(minDist[i], s)
                    if minDist[i] > farD { farD = minDist[i]; far = i }
                }
                centers.append(Array(x[far * d..<(far + 1) * d]))
            }
            var labels = [Int](repeating: 0, count: n)
            for _ in 0..<50 {
                var changed = false
                for i in 0..<n {
                    var best = 0
                    var bestD = Float.greatestFiniteMagnitude
                    for c in 0..<k {
                        var s: Float = 0
                        for j in 0..<d { let v = x[i * d + j] - centers[c][j]; s += v * v }
                        if s < bestD { bestD = s; best = c }
                    }
                    if labels[i] != best { labels[i] = best; changed = true }
                }
                var sums = Array(repeating: [Float](repeating: 0, count: d), count: k)
                var cnt = [Int](repeating: 0, count: k)
                for i in 0..<n {
                    cnt[labels[i]] += 1
                    for j in 0..<d { sums[labels[i]][j] += x[i * d + j] }
                }
                for c in 0..<k where cnt[c] > 0 {
                    centers[c] = sums[c].map { $0 / Float(cnt[c]) }
                }
                if !changed { break }
            }
            var inertia: Float = 0
            for i in 0..<n {
                for j in 0..<d { let v = x[i * d + j] - centers[labels[i]][j]; inertia += v * v }
            }
            if inertia < bestInertia {
                bestInertia = inertia
                bestLabels = labels
            }
        }
        return bestLabels
    }
}
