import Foundation
import Accelerate

/// Pure-Swift local speaker diarization engine using Apple's Accelerate (vDSP) framework.
/// Extracts vocal pitch (F0), Mel-Frequency Cepstral Coefficients (MFCCs), spectral centroid,
/// and subband energy ratios from each transcribed utterance and clusters them by speaker.
enum SpeakerDiarizer {

    // MARK: - Acoustic Feature Extraction

    static func extractEmbedding(samples: [Float], sampleRate: Float) -> AcousticEmbedding? {
        let n = samples.count
        let frameSize = 1024
        let hopSize = 512
        guard n >= frameSize, sampleRate > 4000 else { return nil }

        var hannWindow = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        let halfSize = frameSize / 2
        let log2n = vDSP_Length(round(log2(Double(frameSize))))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Precompute 24 Mel filterbank weights (80 Hz .. min(7600 Hz, sampleRate/2))
        let numMelBands = 24
        let numMFCC = 12
        let melFilterbank = buildMelFilterbank(
            numBands: numMelBands,
            fftBins: halfSize,
            sampleRate: sampleRate,
            lowFreq: 80.0,
            highFreq: min(7600.0, sampleRate * 0.48)
        )
        let dctMatrix = buildDCTMatrix(numCepstra: numMFCC, numBands: numMelBands)

        let minLag = max(8, Int(sampleRate / 400.0))
        let maxLag = min(frameSize / 2, Int(sampleRate / 65.0))
        let binHz = sampleRate / Float(frameSize)

        var f0Values: [Float] = []
        var centroids: [Float] = []
        var subbandAccumulator = [Float](repeating: 0, count: 4)
        var mfccFrames: [[Float]] = []
        var totalFrames = 0
        var voicedFrames = 0

        // Compute adaptive RMS threshold based on segment peak RMS
        var overallRMS: Float = 0
        vDSP_rmsqv(samples, 1, &overallRMS, vDSP_Length(n))
        let rmsThreshold = max(0.0025, overallRMS * 0.25)

        var windowed = [Float](repeating: 0, count: frameSize)
        var realPart = [Float](repeating: 0, count: halfSize)
        var imagPart = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        let freqIndices = (0..<halfSize).map { Float($0) * binHz }

        var offset = 0
        let maxFramesToProcess = 400 // cap per segment for ultra-fast extraction
        let effectiveHop = max(hopSize, (n - frameSize) / max(1, maxFramesToProcess))

        while offset + frameSize <= n {
            totalFrames += 1
            let frameSlice = Array(samples[offset..<(offset + frameSize)])

            var frameRMS: Float = 0
            vDSP_rmsqv(frameSlice, 1, &frameRMS, vDSP_Length(frameSize))

            if frameRMS >= rmsThreshold {
                voicedFrames += 1

                // 1. Pitch F0 via normalized autocorrelation in [65 Hz, 400 Hz]
                var zeroLagEnergy: Float = 0
                vDSP_dotpr(frameSlice, 1, frameSlice, 1, &zeroLagEnergy, vDSP_Length(frameSize))
                if zeroLagEnergy > 1e-7 {
                    var bestLag = 0
                    var bestCorr: Float = 0
                    let coarseStep = 2
                    frameSlice.withUnsafeBufferPointer { ptr in
                        guard let base = ptr.baseAddress else { return }
                        var lag = minLag
                        while lag < maxLag {
                            var corr: Float = 0
                            vDSP_dotpr(base, 1, base + lag, 1, &corr, vDSP_Length(frameSize - lag))
                            let norm = corr / zeroLagEnergy
                            if norm > bestCorr {
                                bestCorr = norm
                                bestLag = lag
                            }
                            lag += coarseStep
                        }
                        // Refine +/- 1 sample around bestLag
                        if bestLag > minLag && bestLag + 1 < maxLag {
                            for refineLag in [bestLag - 1, bestLag + 1] {
                                var corr: Float = 0
                                vDSP_dotpr(base, 1, base + refineLag, 1, &corr, vDSP_Length(frameSize - refineLag))
                                let norm = corr / zeroLagEnergy
                                if norm > bestCorr {
                                    bestCorr = norm
                                    bestLag = refineLag
                                }
                            }
                        }
                    }
                    if bestCorr > 0.32 && bestLag > 0 {
                        let f0 = sampleRate / Float(bestLag)
                        if f0 >= 65.0 && f0 <= 400.0 {
                            f0Values.append(f0)
                        }
                    }
                }

                // 2. Windowed FFT power spectrum
                vDSP_vmul(frameSlice, 1, hannWindow, 1, &windowed, 1, vDSP_Length(frameSize))
                realPart.withUnsafeMutableBufferPointer { rBuf in
                    imagPart.withUnsafeMutableBufferPointer { iBuf in
                        var splitComplex = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                        windowed.withUnsafeBytes { rawBytes in
                            let complexPtr = rawBytes.bindMemory(to: DSPComplex.self)
                            vDSP_ctoz(complexPtr.baseAddress!, 2, &splitComplex, 1, vDSP_Length(halfSize))
                        }
                        vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
                    }
                }

                // Convert power to amplitude spectrum
                for i in 0..<halfSize {
                    magnitudes[i] = sqrtf(max(1e-10, magnitudes[i]))
                }

                var magSum: Float = 0
                vDSP_sve(magnitudes, 1, &magSum, vDSP_Length(halfSize))
                if magSum > 1e-6 {
                    // Spectral centroid
                    var weightedFreqSum: Float = 0
                    vDSP_dotpr(magnitudes, 1, freqIndices, 1, &weightedFreqSum, vDSP_Length(halfSize))
                    centroids.append(weightedFreqSum / magSum)

                    // 4 Subband energy ratios: [80-350, 350-1000, 1000-2800, 2800-7000 Hz]
                    let b0 = max(1, Int(80.0 / binHz))
                    let b1 = min(halfSize - 1, Int(350.0 / binHz))
                    let b2 = min(halfSize - 1, Int(1000.0 / binHz))
                    let b3 = min(halfSize - 1, Int(2800.0 / binHz))
                    let b4 = min(halfSize, Int(7000.0 / binHz))

                    let e0 = b1 > b0 ? magnitudes[b0..<b1].reduce(0, +) / magSum : 0
                    let e1 = b2 > b1 ? magnitudes[b1..<b2].reduce(0, +) / magSum : 0
                    let e2 = b3 > b2 ? magnitudes[b2..<b3].reduce(0, +) / magSum : 0
                    let e3 = b4 > b3 ? magnitudes[b3..<b4].reduce(0, +) / magSum : 0
                    subbandAccumulator[0] += e0
                    subbandAccumulator[1] += e1
                    subbandAccumulator[2] += e2
                    subbandAccumulator[3] += e3

                    // 3. Mel Filterbank -> Log -> DCT -> MFCC (c1..c12)
                    var logMel = [Float](repeating: 0, count: numMelBands)
                    for m in 0..<numMelBands {
                        var melEnergy: Float = 0
                        vDSP_dotpr(magnitudes, 1, melFilterbank[m], 1, &melEnergy, vDSP_Length(halfSize))
                        logMel[m] = logf(max(1e-7, melEnergy))
                    }
                    // Cepstral mean subtraction across Mel bands (removes channel gain)
                    let melMean = logMel.reduce(0, +) / Float(numMelBands)
                    for m in 0..<numMelBands {
                        logMel[m] -= melMean
                    }

                    var mfcc = [Float](repeating: 0, count: numMFCC)
                    for c in 0..<numMFCC {
                        var val: Float = 0
                        vDSP_dotpr(logMel, 1, dctMatrix[c], 1, &val, vDSP_Length(numMelBands))
                        mfcc[c] = val
                    }
                    mfccFrames.append(mfcc)
                }
            }

            offset += effectiveHop
        }

        guard voicedFrames > 0, !mfccFrames.isEmpty else { return nil }

        // F0 statistics
        let f0Median: Float
        let f0IQR: Float
        if !f0Values.isEmpty {
            let sortedF0 = f0Values.sorted()
            f0Median = sortedF0[sortedF0.count / 2]
            let q25 = sortedF0[max(0, sortedF0.count / 4)]
            let q75 = sortedF0[min(sortedF0.count - 1, (sortedF0.count * 3) / 4)]
            f0IQR = max(1.0, q75 - q25)
        } else {
            f0Median = 155.0
            f0IQR = 20.0
        }

        let centroidMean = centroids.isEmpty ? 1200.0 : (centroids.reduce(0, +) / Float(centroids.count))
        let invVoiced = 1.0 / Float(max(1, centroids.count))
        let subbandRatios = subbandAccumulator.map { $0 * invVoiced }

        // MFCC means (c1..c12) and stds (c1..c6)
        let frameCountFloat = Float(mfccFrames.count)
        var mfccMeans = [Float](repeating: 0, count: numMFCC)
        for frame in mfccFrames {
            for c in 0..<numMFCC {
                mfccMeans[c] += frame[c]
            }
        }
        for c in 0..<numMFCC {
            mfccMeans[c] /= frameCountFloat
        }

        let numStd = 6
        var mfccStds = [Float](repeating: 0, count: numStd)
        for frame in mfccFrames {
            for c in 0..<numStd {
                let diff = frame[c] - mfccMeans[c]
                mfccStds[c] += diff * diff
            }
        }
        for c in 0..<numStd {
            mfccStds[c] = sqrtf(mfccStds[c] / frameCountFloat)
        }

        let voicedRatio = Float(voicedFrames) / Float(max(1, totalFrames))

        return AcousticEmbedding(
            f0Median: f0Median,
            f0IQR: f0IQR,
            spectralCentroid: centroidMean,
            subbandRatios: subbandRatios,
            mfccMeans: mfccMeans,
            mfccStds: mfccStds,
            voicedRatio: voicedRatio
        )
    }

    // MARK: - Speaker Clustering (Diarization)

    /// Assigns speaker IDs (1...K) to all segments based on their acoustic embeddings and temporal proximity.
    static func assignSpeakers(
        segments: inout [TranscriptSegment],
        mode: SpeakerCountMode
    ) {
        guard !segments.isEmpty else { return }

        if mode == .off {
            for i in segments.indices {
                segments[i].speakerID = 1
            }
            return
        }

        // Collect valid embeddings (prefer segments with duration >= 0.45s for anchor clustering)
        let validIndices = segments.indices.filter { segments[$0].embedding != nil }
        guard validIndices.count >= 2 else {
            for i in segments.indices {
                segments[i].speakerID = 1
            }
            return
        }

        let rawVectors = validIndices.map { segments[$0].embedding!.featureVector }
        let dim = rawVectors[0].count

        // Feature importance weights:
        // Index 0: logF0 (high weight 2.8)
        // Index 1: F0 IQR (weight 0.8)
        // Index 2: Spectral Centroid (weight 1.3)
        // Index 3..6: 4 Subband ratios (weight 1.2)
        // Index 7..18: 12 MFCC means (weight 1.6 for c1..c6, 1.1 for c7..c12)
        // Index 19..24: 6 MFCC stds (weight 0.6)
        var featureWeights = [Float](repeating: 1.0, count: dim)
        if dim >= 25 {
            featureWeights[0] = 2.8
            featureWeights[1] = 0.8
            featureWeights[2] = 1.3
            for i in 3...6 { featureWeights[i] = 1.2 }
            for i in 7...12 { featureWeights[i] = 1.6 }
            for i in 13...18 { featureWeights[i] = 1.1 }
            for i in 19...24 { featureWeights[i] = 0.6 }
        }

        // Standardize features across segments using mean and standard deviation
        var means = [Float](repeating: 0, count: dim)
        var stds = [Float](repeating: 0, count: dim)
        let countFloat = Float(rawVectors.count)

        for vec in rawVectors {
            for d in 0..<dim {
                means[d] += vec[d]
            }
        }
        for d in 0..<dim {
            means[d] /= countFloat
        }
        for vec in rawVectors {
            for d in 0..<dim {
                let diff = vec[d] - means[d]
                stds[d] += diff * diff
            }
        }
        for d in 0..<dim {
            stds[d] = max(1e-4, sqrtf(stds[d] / countFloat))
        }

        let normalizedVectors: [[Float]] = rawVectors.map { vec in
            var norm = [Float](repeating: 0, count: dim)
            for d in 0..<dim {
                norm[d] = ((vec[d] - means[d]) / stds[d]) * featureWeights[d]
            }
            return norm
        }

        // Determine target speaker count K
        let targetK: Int
        if mode == .auto {
            targetK = estimateOptimalSpeakerCount(
                vectors: normalizedVectors,
                rawEmbeddings: validIndices.map { segments[$0].embedding! }
            )
        } else {
            targetK = min(mode.rawValue, validIndices.count)
        }

        if targetK <= 1 {
            for i in segments.indices {
                segments[i].speakerID = 1
            }
            return
        }

        // Run K-Means++ with multiple deterministic seeds and pick lowest inertia
        var rawLabels = runKMeansPlusPlus(vectors: normalizedVectors, k: targetK)

        // Temporal smoothing: if a very short segment (< 1.1s) is sandwiched between two segments of the same speaker
        // and occurs shortly after the previous segment, smooth its label unless its pitch differs strongly.
        if validIndices.count >= 3 {
            var smoothed = rawLabels
            for i in 1..<(validIndices.count - 1) {
                let segIdx = validIndices[i]
                let prevSegIdx = validIndices[i - 1]
                let nextSegIdx = validIndices[i + 1]
                let seg = segments[segIdx]
                if seg.duration < 1.1 && rawLabels[i - 1] == rawLabels[i + 1] && rawLabels[i] != rawLabels[i - 1] {
                    let gapBefore = seg.startTime - segments[prevSegIdx].endTime
                    let gapAfter = segments[nextSegIdx].startTime - seg.endTime
                    if gapBefore < 1.5 && gapAfter < 1.5 {
                        smoothed[i] = rawLabels[i - 1]
                    }
                }
            }
            rawLabels = smoothed
        }

        // Canonicalize speaker numbers in order of first appearance (1, 2, 3, ...)
        var clusterToSpeakerID: [Int: Int] = [:]
        var nextSpeakerID = 1
        for label in rawLabels {
            if clusterToSpeakerID[label] == nil {
                clusterToSpeakerID[label] = nextSpeakerID
                nextSpeakerID += 1
            }
        }

        for (i, segIdx) in validIndices.enumerated() {
            segments[segIdx].speakerID = clusterToSpeakerID[rawLabels[i]] ?? 1
        }

        // Fill any segments without embeddings from nearest neighbor in time
        for i in segments.indices where segments[i].embedding == nil {
            if i > 0 {
                segments[i].speakerID = segments[i - 1].speakerID
            } else if i + 1 < segments.count {
                segments[i].speakerID = segments[i + 1].speakerID
            } else {
                segments[i].speakerID = 1
            }
        }
    }

    // MARK: - Automatic Speaker Count Estimation

    private static func estimateOptimalSpeakerCount(
        vectors: [[Float]],
        rawEmbeddings: [AcousticEmbedding]
    ) -> Int {
        guard vectors.count >= 4 else { return 1 }

        // Check acoustic spread: if F0 variation and MFCC variation across the whole file are both very small,
        // it may be a single speaker. However, same-gender speakers can have similar F0 and differ in MFCCs.
        let f0List = rawEmbeddings.map { $0.f0Median }.sorted()
        let f0P10 = f0List[max(0, Int(Double(f0List.count) * 0.10))]
        let f0P90 = f0List[min(f0List.count - 1, Int(Double(f0List.count) * 0.90))]
        let f0Ratio = f0P10 > 0 ? (f0P90 / f0P10) : 1.0

        let maxK = min(5, max(2, vectors.count / 3))
        var bestK = 2
        var bestScore: Float = -1.0

        for k in 2...maxK {
            let labels = runKMeansPlusPlus(vectors: vectors, k: k)
            let sil = computeSilhouetteScore(vectors: vectors, labels: labels, k: k)
            // Penalize higher k slightly to prefer parsimonious speaker counts
            let penalizedScore = sil - Float(k - 2) * 0.025
            if penalizedScore > bestScore {
                bestScore = penalizedScore
                bestK = k
            }
        }

        // If silhouette score is very weak and F0 spread is narrow, default to 1 speaker
        if bestScore < 0.11 && f0Ratio < 1.15 {
            return 1
        }
        return bestK
    }

    private static func runKMeansPlusPlus(vectors: [[Float]], k: Int) -> [Int] {
        let n = vectors.count
        guard n > k, k > 1 else { return Array(0..<n).map { $0 % max(1, k) } }
        let dim = vectors[0].count

        var bestLabels = [Int](repeating: 0, count: n)
        var bestInertia: Float = .greatestFiniteMagnitude

        let numRestarts = min(6, n)
        for seedIdx in 0..<numRestarts {
            let firstCenterIdx = (seedIdx * max(1, n / numRestarts)) % n
            var centers: [[Float]] = [vectors[firstCenterIdx]]

            // K-Means++ deterministic farthest-first / quantile initialization
            var minDistSq = [Float](repeating: .greatestFiniteMagnitude, count: n)
            for _ in 1..<k {
                for i in 0..<n {
                    let d = squaredDistance(vectors[i], centers.last!)
                    if d < minDistSq[i] {
                        minDistSq[i] = d
                    }
                }
                // Pick the point with maximum distance to existing centers
                var farthestIdx = 0
                var maxD: Float = -1
                for i in 0..<n {
                    if minDistSq[i] > maxD {
                        maxD = minDistSq[i]
                        farthestIdx = i
                    }
                }
                centers.append(vectors[farthestIdx])
            }

            var labels = [Int](repeating: 0, count: n)
            for _ in 0..<30 {
                var changed = false
                for i in 0..<n {
                    var bestC = 0
                    var bestD: Float = .greatestFiniteMagnitude
                    for c in 0..<k {
                        let d = squaredDistance(vectors[i], centers[c])
                        if d < bestD {
                            bestD = d
                            bestC = c
                        }
                    }
                    if labels[i] != bestC {
                        labels[i] = bestC
                        changed = true
                    }
                }
                if !changed { break }

                var newCenters = Array(repeating: [Float](repeating: 0, count: dim), count: k)
                var counts = [Int](repeating: 0, count: k)
                for i in 0..<n {
                    let c = labels[i]
                    counts[c] += 1
                    for d in 0..<dim {
                        newCenters[c][d] += vectors[i][d]
                    }
                }
                for c in 0..<k {
                    if counts[c] > 0 {
                        let inv = 1.0 / Float(counts[c])
                        for d in 0..<dim {
                            newCenters[c][d] *= inv
                        }
                    } else {
                        newCenters[c] = centers[c]
                    }
                }
                centers = newCenters
            }

            var inertia: Float = 0
            for i in 0..<n {
                inertia += squaredDistance(vectors[i], centers[labels[i]])
            }
            if inertia < bestInertia {
                bestInertia = inertia
                bestLabels = labels
            }
        }

        return bestLabels
    }

    private static func computeSilhouetteScore(vectors: [[Float]], labels: [Int], k: Int) -> Float {
        let n = vectors.count
        guard n > k, k > 1 else { return 0 }

        // Check cluster sizes
        var counts = [Int](repeating: 0, count: k)
        for l in labels {
            if l >= 0 && l < k { counts[l] += 1 }
        }
        let nonEmptyClusters = counts.filter { $0 > 0 }.count
        guard nonEmptyClusters > 1 else { return 0 }

        var totalSil: Float = 0
        for i in 0..<n {
            let ownCluster = labels[i]
            var intraSum: Float = 0
            var intraCount = 0
            var clusterSums = [Float](repeating: 0, count: k)
            var clusterCounts = [Int](repeating: 0, count: k)

            for j in 0..<n where i != j {
                let d = sqrtf(squaredDistance(vectors[i], vectors[j]))
                let cj = labels[j]
                if cj == ownCluster {
                    intraSum += d
                    intraCount += 1
                } else {
                    clusterSums[cj] += d
                    clusterCounts[cj] += 1
                }
            }

            let a = intraCount > 0 ? (intraSum / Float(intraCount)) : 0
            var b: Float = .greatestFiniteMagnitude
            for c in 0..<k where c != ownCluster && clusterCounts[c] > 0 {
                let meanDist = clusterSums[c] / Float(clusterCounts[c])
                if meanDist < b {
                    b = meanDist
                }
            }
            if b.isFinite && max(a, b) > 1e-6 {
                totalSil += (b - a) / max(a, b)
            }
        }

        return totalSil / Float(n)
    }

    private static func squaredDistance(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for i in 0..<min(a.count, b.count) {
            let diff = a[i] - b[i]
            sum += diff * diff
        }
        return sum
    }

    // MARK: - Mel & DCT Helper Matrices

    private static func hzToMel(_ hz: Float) -> Float {
        2595.0 * log10f(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        700.0 * (powf(10.0, mel / 2595.0) - 1.0)
    }

    private static func buildMelFilterbank(
        numBands: Int,
        fftBins: Int,
        sampleRate: Float,
        lowFreq: Float,
        highFreq: Float
    ) -> [[Float]] {
        let lowMel = hzToMel(lowFreq)
        let highMel = hzToMel(highFreq)
        let melStep = (highMel - lowMel) / Float(numBands + 1)

        let fftSize = Float(fftBins * 2)
        var binPoints = [Int](repeating: 0, count: numBands + 2)
        for i in 0..<(numBands + 2) {
            let hz = melToHz(lowMel + Float(i) * melStep)
            let bin = Int(floor((fftSize + 1.0) * hz / sampleRate))
            binPoints[i] = max(0, min(fftBins - 1, bin))
        }

        var filterbank = Array(repeating: [Float](repeating: 0, count: fftBins), count: numBands)
        for m in 1...numBands {
            let fLeft = binPoints[m - 1]
            let fCenter = max(fLeft + 1, binPoints[m])
            let fRight = max(fCenter + 1, min(fftBins - 1, binPoints[m + 1]))

            for k in fLeft..<fCenter {
                filterbank[m - 1][k] = Float(k - fLeft) / Float(max(1, fCenter - fLeft))
            }
            for k in fCenter...fRight {
                filterbank[m - 1][k] = Float(fRight - k) / Float(max(1, fRight - fCenter))
            }
        }
        return filterbank
    }

    /// Builds DCT-II matrix for cepstral coefficients c1..numCepstra (skipping c0 energy).
    private static func buildDCTMatrix(numCepstra: Int, numBands: Int) -> [[Float]] {
        var matrix = Array(repeating: [Float](repeating: 0, count: numBands), count: numCepstra)
        let scale = sqrtf(2.0 / Float(numBands))
        for c in 1...numCepstra {
            for m in 0..<numBands {
                let angle = Float.pi * Float(c) * (Float(m) + 0.5) / Float(numBands)
                matrix[c - 1][m] = scale * cosf(angle)
            }
        }
        return matrix
    }
}
