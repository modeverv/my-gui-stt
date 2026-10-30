import Foundation
import SwiftUI

// MARK: - Transcription Engine Options

enum TranscriptionEngineType: String, CaseIterable, Identifiable, Sendable {
    case speechTranscriber = "speech_transcriber"
    case dictationTranscriber = "dictation_transcriber"
    case sfSpeechRecognizer = "sf_speech_recognizer"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speechTranscriber:
            return "Apple SpeechTranscriber (最新・長尺高速・推奨)"
        case .dictationTranscriber:
            return "Apple DictationTranscriber (ディクテーション特化)"
        case .sfSpeechRecognizer:
            return "Apple SFSpeechRecognizer (従来型・チャンク分割)"
        }
    }

    var shortDescription: String {
        switch self {
        case .speechTranscriber:
            return "macOS最新のオンデバイスNeural音声認識エンジン。長尺の動画・音声ファイルを高速かつ文字単位の精密タイムスタンプ付きで文字起こしします。"
        case .dictationTranscriber:
            return "句読点補完や音声入力向けに最適化されたAppleオンデバイスモデルです。"
        case .sfSpeechRecognizer:
            return "従来型のオンデバイスSFSpeechRecognizerを使用し、長尺音声を自動分割して処理します。"
        }
    }
}

// MARK: - Speaker Diarization Mode

enum SpeakerCountMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case auto = -1
    case two = 2
    case three = 3
    case four = 4
    case five = 5
    case six = 6

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off: return "オフ (話者分離なし)"
        case .auto: return "自動推定 (音響クラスタリング)"
        case .two: return "2人"
        case .three: return "3人"
        case .four: return "4人"
        case .five: return "5人"
        case .six: return "6人"
        }
    }
}

// MARK: - Export Formats

enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case txt = "txt"
    case srt = "srt"
    case vtt = "vtt"
    case markdown = "md"
    case json = "json"
    case csv = "csv"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: return "プレーンテキスト (.txt)"
        case .srt: return "SRT 字幕ファイル (.srt)"
        case .vtt: return "WebVTT 字幕ファイル (.vtt)"
        case .markdown: return "Markdown ドキュメント (.md)"
        case .json: return "JSON データ (.json)"
        case .csv: return "CSV テーブル (.csv)"
        }
    }

    var fileExtension: String { rawValue }
}

// MARK: - Token & Segment Models

struct TranscriptToken: Sendable, Equatable {
    var text: String
    var startTime: Double
    var endTime: Double
    var confidence: Double?
}

struct AcousticEmbedding: Sendable, Equatable, Codable {
    /// Fundamental frequency (Hz) median over voiced frames
    var f0Median: Float
    /// Fundamental frequency interquartile range (Hz)
    var f0IQR: Float
    /// Spectral centroid (Hz)
    var spectralCentroid: Float
    /// 4 subband log-energy ratios
    var subbandRatios: [Float]
    /// 12 MFCC means (c1..c12)
    var mfccMeans: [Float]
    /// 6 MFCC standard deviations (c1..c6)
    var mfccStds: [Float]
    /// Fraction of voiced frames in segment
    var voicedRatio: Float

    /// Combined raw feature vector used for speaker clustering
    var featureVector: [Float] {
        let logF0 = f0Median > 40 ? log2(f0Median / 100.0) : 0.0
        let normIQR = f0Median > 40 ? (f0IQR / f0Median) : 0.0
        let normCentroid = spectralCentroid / 2500.0
        var vec: [Float] = [logF0, normIQR, normCentroid]
        vec.append(contentsOf: subbandRatios)
        vec.append(contentsOf: mfccMeans)
        vec.append(contentsOf: mfccStds)
        return vec
    }
}

struct TranscriptSegment: Identifiable, Equatable, Sendable, Codable {
    var id: UUID = UUID()
    var index: Int
    var startTime: Double
    var endTime: Double
    var text: String
    var speakerID: Int
    var confidence: Double?
    var embedding: AcousticEmbedding?

    var duration: Double {
        max(0, endTime - startTime)
    }

    var formattedTimeRange: String {
        "\(TimeFormatter.format(startTime, includeMillis: true)) - \(TimeFormatter.format(endTime, includeMillis: true))"
    }

    var formattedShortTimeRange: String {
        "\(TimeFormatter.format(startTime, includeMillis: false)) - \(TimeFormatter.format(endTime, includeMillis: false))"
    }
}

struct SpeakerInfo: Identifiable, Equatable, Sendable {
    var id: Int
    var name: String
    var averageF0: Float?
    var segmentCount: Int
    var totalDuration: Double

    static let palette: [Color] = [
        Color(red: 0.16, green: 0.50, blue: 0.96), // Blue
        Color(red: 0.15, green: 0.68, blue: 0.38), // Green
        Color(red: 0.90, green: 0.49, blue: 0.13), // Orange
        Color(red: 0.61, green: 0.35, blue: 0.71), // Purple
        Color(red: 0.91, green: 0.26, blue: 0.42), // Pink/Red
        Color(red: 0.09, green: 0.63, blue: 0.65), // Teal
        Color(red: 0.55, green: 0.43, blue: 0.28), // Brown
        Color(red: 0.40, green: 0.48, blue: 0.56)  // Slate
    ]

    static func color(for speakerID: Int) -> Color {
        guard speakerID > 0 else { return .secondary }
        return palette[(speakerID - 1) % palette.count]
    }
}

// MARK: - Locale Info

struct SupportedLocaleItem: Identifiable, Equatable, Hashable, Sendable {
    var identifier: String
    var displayName: String
    var isInstalled: Bool

    var id: String { identifier }

    var labelWithStatus: String {
        if isInstalled {
            return "\(displayName) (\(identifier)) [ローカル済]"
        } else {
            return "\(displayName) (\(identifier))"
        }
    }
}

// MARK: - Media File Info

struct MediaFileInfo: Equatable, Sendable {
    var url: URL
    var fileName: String
    var fileSizeByteCount: Int64
    var durationSeconds: Double
    var hasVideo: Bool
    var sampleRate: Double
    var channelCount: Int
    var formatSummary: String

    var formattedDuration: String {
        TimeFormatter.format(durationSeconds, includeMillis: false)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeByteCount, countStyle: .file)
    }
}

// MARK: - Time Formatting Helper

enum TimeFormatter {
    static func format(_ seconds: Double, includeMillis: Bool = true) -> String {
        guard seconds.isFinite && seconds >= 0 else { return includeMillis ? "00:00.00" : "00:00" }
        let totalSecs = Int(seconds)
        let hours = totalSecs / 3600
        let mins = (totalSecs % 3600) / 60
        let secs = totalSecs % 60
        let centis = Int((seconds - Double(totalSecs)) * 100)

        if hours > 0 {
            if includeMillis {
                return String(format: "%02d:%02d:%02d.%02d", hours, mins, secs, centis)
            } else {
                return String(format: "%02d:%02d:%02d", hours, mins, secs)
            }
        } else {
            if includeMillis {
                return String(format: "%02d:%02d.%02d", mins, secs, centis)
            } else {
                return String(format: "%02d:%02d", mins, secs)
            }
        }
    }

    static func formatSRT(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalSecs = Int(clamped)
        let hours = totalSecs / 3600
        let mins = (totalSecs % 3600) / 60
        let secs = totalSecs % 60
        let millis = Int(((clamped - Double(totalSecs)) * 1000).rounded()) % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, mins, secs, millis)
    }

    static func formatVTT(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalSecs = Int(clamped)
        let hours = totalSecs / 3600
        let mins = (totalSecs % 3600) / 60
        let secs = totalSecs % 60
        let millis = Int(((clamped - Double(totalSecs)) * 1000).rounded()) % 1000
        return String(format: "%02d:%02d:%02d.%03d", hours, mins, secs, millis)
    }
}
