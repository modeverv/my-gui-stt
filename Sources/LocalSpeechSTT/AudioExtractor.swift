import Foundation
import AVFoundation
import Accelerate

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case readerCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "選択されたファイルに音声トラックが含まれていません。"
        case .readerCreationFailed:
            return "音声データの読み込み初期化に失敗しました。"
        case .exportFailed(let msg):
            return "動画からの音声抽出に失敗しました: \(msg)"
        }
    }
}

final class AudioSampleReader {
    let audioFileURL: URL
    private let audioFile: AVAudioFile
    let sampleRate: Double
    let totalFrames: AVAudioFramePosition
    let durationSeconds: Double
    private let isTemporaryFile: Bool

    init(audioFileURL: URL, isTemporaryFile: Bool = false) throws {
        self.audioFileURL = audioFileURL
        self.audioFile = try AVAudioFile(forReading: audioFileURL)
        self.sampleRate = audioFile.processingFormat.sampleRate
        self.totalFrames = audioFile.length
        self.durationSeconds = sampleRate > 0 ? Double(totalFrames) / sampleRate : 0
        self.isTemporaryFile = isTemporaryFile
    }

    deinit {
        if isTemporaryFile {
            try? FileManager.default.removeItem(at: audioFileURL)
        }
    }

    /// Reads mono Float32 samples for the specified time range [startTime, endTime].
    func readMonoSamples(startTime: Double, endTime: Double, maxDuration: Double = 12.0) -> (samples: [Float], sampleRate: Float)? {
        guard sampleRate > 0, endTime > startTime else { return nil }
        let clampedStart = max(0.0, startTime)
        let clampedDur = min(maxDuration, max(0.15, endTime - clampedStart))
        let startFrame = AVAudioFramePosition(clampedStart * sampleRate)
        guard startFrame < totalFrames else { return nil }

        let availableFrames = totalFrames - startFrame
        let requestedFrames = AVAudioFramePosition(clampedDur * sampleRate)
        let frameCount = AVAudioFrameCount(min(availableFrames, requestedFrames))
        guard frameCount >= 512 else { return nil }

        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        audioFile.framePosition = startFrame
        do {
            try audioFile.read(into: buffer, frameCount: frameCount)
        } catch {
            return nil
        }

        let actualLength = Int(buffer.frameLength)
        guard actualLength >= 512, let channelData = buffer.floatChannelData else {
            return nil
        }

        let channels = Int(format.channelCount)
        if channels == 1 {
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: actualLength))
            return (samples, Float(sampleRate))
        } else {
            // Mix down to mono
            var mono = [Float](repeating: 0, count: actualLength)
            let scale = 1.0 / Float(channels)
            for ch in 0..<channels {
                vDSP_vadd(mono, 1, channelData[ch], 1, &mono, 1, vDSP_Length(actualLength))
            }
            var s = scale
            vDSP_vsmul(mono, 1, &s, &mono, 1, vDSP_Length(actualLength))
            return (mono, Float(sampleRate))
        }
    }

    /// Extracts a downsampled waveform envelope (0.0 ... 1.0) for UI visualization.
    func extractWaveformEnvelope(bucketCount: Int = 160) -> [Float] {
        guard bucketCount > 0, totalFrames > 0 else { return [] }
        let framesPerBucket = max(1, Int(totalFrames) / bucketCount)
        let sampleWindow = min(framesPerBucket, 4096)
        let format = audioFile.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleWindow)) else {
            return []
        }

        var peaks = [Float](repeating: 0, count: bucketCount)
        for i in 0..<bucketCount {
            let pos = AVAudioFramePosition(i * framesPerBucket)
            if pos >= totalFrames { break }
            audioFile.framePosition = pos
            let toRead = AVAudioFrameCount(min(Int64(sampleWindow), totalFrames - pos))
            if (try? audioFile.read(into: buffer, frameCount: toRead)) != nil,
               buffer.frameLength > 0,
               let ch0 = buffer.floatChannelData?[0] {
                var rms: Float = 0
                vDSP_rmsqv(ch0, 1, &rms, vDSP_Length(buffer.frameLength))
                peaks[i] = rms
            }
        }

        var maxPeak: Float = 0
        vDSP_maxv(peaks, 1, &maxPeak, vDSP_Length(bucketCount))
        if maxPeak > 1e-6 {
            var scale = 1.0 / maxPeak
            vDSP_vsmul(peaks, 1, &scale, &peaks, 1, vDSP_Length(bucketCount))
        }
        return peaks.map { min(1.0, max(0.05, pow($0, 0.65))) }
    }
}

enum MediaInspector {
    /// Inspects any audio or video file and returns metadata.
    static func inspect(url: URL) async throws -> MediaFileInfo {
        let asset = AVURLAsset(url: url)
        let durationCM = try await asset.load(.duration)
        let durationSeconds = max(0, CMTimeGetSeconds(durationCM))

        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !audioTracks.isEmpty else {
            throw AudioExtractorError.noAudioTrack
        }

        var sampleRate: Double = 44100
        var channelCount: Int = 1
        if let firstAudio = audioTracks.first,
           let formatDescriptions = try? await firstAudio.load(.formatDescriptions),
           let firstDesc = formatDescriptions.first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(firstDesc)?.pointee {
            if basic.mSampleRate > 0 {
                sampleRate = basic.mSampleRate
            }
            if basic.mChannelsPerFrame > 0 {
                channelCount = Int(basic.mChannelsPerFrame)
            }
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let ext = url.pathExtension.uppercased()
        let mediaKind = videoTracks.isEmpty ? "音声" : "動画"
        let summary = "\(mediaKind) (\(ext)) • \(Int(sampleRate)) Hz • \(channelCount)ch"

        return MediaFileInfo(
            url: url,
            fileName: url.lastPathComponent,
            fileSizeByteCount: fileSize,
            durationSeconds: durationSeconds,
            hasVideo: !videoTracks.isEmpty,
            sampleRate: sampleRate,
            channelCount: channelCount,
            formatSummary: summary
        )
    }

    /// Opens the media file as an `AudioSampleReader`. If the file is a video container that `AVAudioFile`
    /// cannot open directly, extracts the audio track into a temporary linear PCM `.caf` file.
    static func prepareAudioReader(for url: URL) async throws -> AudioSampleReader {
        // Fast path: if AVAudioFile can open the file directly and it has frames
        if let directReader = try? AudioSampleReader(audioFileURL: url, isTemporaryFile: false),
           directReader.totalFrames > 0 {
            return directReader
        }

        // Fallback for video containers (.mp4, .mov, .m4v, etc.): extract audio via AVAssetReader to temp .caf
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw AudioExtractorError.noAudioTrack
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioExtractorError.readerCreationFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw AudioExtractorError.readerCreationFailed
        }
        reader.add(trackOutput)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt_extracted_\(UUID().uuidString).caf")

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioExtractorError.readerCreationFailed
        }

        do {
            let outFile = try AVAudioFile(forWriting: tempURL, settings: outFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard reader.startReading() else {
                throw AudioExtractorError.exportFailed(reader.error?.localizedDescription ?? "不明なエラー")
            }

            while reader.status == .reading {
                guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else { break }
                let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
                if numSamples > 0,
                   let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
                   let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(numSamples)),
                   let dstPtr = pcmBuffer.floatChannelData?[0] {
                    pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
                    CMBlockBufferCopyDataBytes(
                        blockBuffer,
                        atOffset: 0,
                        dataLength: numSamples * MemoryLayout<Float>.size,
                        destination: dstPtr
                    )
                    try outFile.write(from: pcmBuffer)
                }
            }

            if reader.status == .failed {
                try? FileManager.default.removeItem(at: tempURL)
                throw AudioExtractorError.exportFailed(reader.error?.localizedDescription ?? "読み込み中断")
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return try AudioSampleReader(audioFileURL: tempURL, isTemporaryFile: true)
    }
}
