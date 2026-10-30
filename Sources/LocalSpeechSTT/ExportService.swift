import Foundation

struct ExportOptions: Sendable {
    var includeTimestamps: Bool = true
    var includeSpeakers: Bool = true
    var mergeConsecutiveSameSpeaker: Bool = false
}

enum ExportService {

    static func formatTranscript(
        segments: [TranscriptSegment],
        speakerNames: [Int: String],
        mediaInfo: MediaFileInfo?,
        format: ExportFormat,
        options: ExportOptions
    ) -> String {
        let effectiveSegments = options.mergeConsecutiveSameSpeaker
            ? mergeConsecutiveBySpeaker(segments: segments)
            : segments

        switch format {
        case .txt:
            return renderPlainText(segments: effectiveSegments, speakerNames: speakerNames, options: options)
        case .srt:
            return renderSRT(segments: effectiveSegments, speakerNames: speakerNames, options: options)
        case .vtt:
            return renderVTT(segments: effectiveSegments, speakerNames: speakerNames, options: options)
        case .markdown:
            return renderMarkdown(segments: effectiveSegments, speakerNames: speakerNames, mediaInfo: mediaInfo, options: options)
        case .json:
            return renderJSON(segments: effectiveSegments, speakerNames: speakerNames, mediaInfo: mediaInfo)
        case .csv:
            return renderCSV(segments: effectiveSegments, speakerNames: speakerNames)
        }
    }

    static func mergeConsecutiveBySpeaker(segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }
        var merged: [TranscriptSegment] = []

        for seg in segments {
            if var last = merged.last,
               last.speakerID == seg.speakerID,
               (seg.startTime - last.endTime) < 4.0 {
                let needsSpace = shouldInsertSpace(between: last.text, and: seg.text)
                last.text += (needsSpace ? " " : "") + seg.text
                last.endTime = seg.endTime
                merged[merged.count - 1] = last
            } else {
                var copy = seg
                copy.index = merged.count + 1
                merged.append(copy)
            }
        }
        return merged
    }

    private static func shouldInsertSpace(between a: String, and b: String) -> Bool {
        guard let lastChar = a.last, let firstChar = b.first else { return false }
        let isLastASCII = lastChar.isASCII && (lastChar.isLetter || lastChar.isNumber || lastChar == "." || lastChar == ",")
        let isFirstASCII = firstChar.isASCII && (firstChar.isLetter || firstChar.isNumber)
        return isLastASCII && isFirstASCII
    }

    private static func speakerLabel(for speakerID: Int, speakerNames: [Int: String]) -> String {
        if let custom = speakerNames[speakerID], !custom.trimmingCharacters(in: .whitespaces).isEmpty {
            return custom
        }
        return "話者 \(speakerID)"
    }

    // MARK: - Plain Text (.txt)

    private static func renderPlainText(
        segments: [TranscriptSegment],
        speakerNames: [Int: String],
        options: ExportOptions
    ) -> String {
        segments.map { seg in
            var prefixParts: [String] = []
            if options.includeTimestamps {
                prefixParts.append("[\(seg.formattedTimeRange)]")
            }
            if options.includeSpeakers {
                prefixParts.append("\(speakerLabel(for: seg.speakerID, speakerNames: speakerNames)):")
            }
            if prefixParts.isEmpty {
                return seg.text
            } else {
                return "\(prefixParts.joined(separator: " ")) \(seg.text)"
            }
        }.joined(separator: "\n")
    }

    // MARK: - SubRip (.srt)

    private static func renderSRT(
        segments: [TranscriptSegment],
        speakerNames: [Int: String],
        options: ExportOptions
    ) -> String {
        segments.enumerated().map { idx, seg in
            let startStr = TimeFormatter.formatSRT(seg.startTime)
            let endStr = TimeFormatter.formatSRT(seg.endTime)
            let body: String
            if options.includeSpeakers {
                body = "[\(speakerLabel(for: seg.speakerID, speakerNames: speakerNames))] \(seg.text)"
            } else {
                body = seg.text
            }
            return "\(idx + 1)\n\(startStr) --> \(endStr)\n\(body)"
        }.joined(separator: "\n\n") + "\n"
    }

    // MARK: - WebVTT (.vtt)

    private static func renderVTT(
        segments: [TranscriptSegment],
        speakerNames: [Int: String],
        options: ExportOptions
    ) -> String {
        var lines = ["WEBVTT", ""]
        for (idx, seg) in segments.enumerated() {
            let startStr = TimeFormatter.formatVTT(seg.startTime)
            let endStr = TimeFormatter.formatVTT(seg.endTime)
            lines.append("\(idx + 1)")
            lines.append("\(startStr) --> \(endStr)")
            if options.includeSpeakers {
                let spk = speakerLabel(for: seg.speakerID, speakerNames: speakerNames)
                lines.append("<v \(spk)>\(seg.text)")
            } else {
                lines.append(seg.text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Markdown (.md)

    private static func renderMarkdown(
        segments: [TranscriptSegment],
        speakerNames: [Int: String],
        mediaInfo: MediaFileInfo?,
        options: ExportOptions
    ) -> String {
        var md: [String] = []
        let title = mediaInfo?.fileName ?? "文字起こし結果"
        md.append("# \(title)")
        md.append("")
        if let info = mediaInfo {
            md.append("- **再生時間**: \(info.formattedDuration)")
            md.append("- **フォーマット**: \(info.formatSummary)")
            md.append("- **セグメント数**: \(segments.count)")
            let totalChars = segments.reduce(0) { $0 + $1.text.count }
            md.append("- **総文字数**: \(totalChars) 文字")
            md.append("")
        }
        md.append("## 文字起こし本文")
        md.append("")
        for seg in segments {
            var headerParts: [String] = []
            if options.includeTimestamps {
                headerParts.append("`\(seg.formattedTimeRange)`")
            }
            if options.includeSpeakers {
                headerParts.append("**\(speakerLabel(for: seg.speakerID, speakerNames: speakerNames))**")
            }
            if headerParts.isEmpty {
                md.append(seg.text)
            } else {
                md.append("- \(headerParts.joined(separator: " ")) — \(seg.text)")
            }
        }
        md.append("")
        return md.joined(separator: "\n")
    }

    // MARK: - JSON (.json)

    private static func renderJSON(
        segments: [TranscriptSegment],
        speakerNames: [Int: String],
        mediaInfo: MediaFileInfo?
    ) -> String {
        struct JSONSegmentItem: Codable {
            var index: Int
            var startTime: Double
            var endTime: Double
            var formattedTimeRange: String
            var speakerID: Int
            var speakerName: String
            var text: String
            var pitchF0Hz: Float?
        }

        struct JSONExportPayload: Codable {
            var fileName: String?
            var durationSeconds: Double?
            var segmentCount: Int
            var segments: [JSONSegmentItem]
        }

        let items = segments.enumerated().map { idx, seg in
            JSONSegmentItem(
                index: idx + 1,
                startTime: (seg.startTime * 100).rounded() / 100,
                endTime: (seg.endTime * 100).rounded() / 100,
                formattedTimeRange: seg.formattedTimeRange,
                speakerID: seg.speakerID,
                speakerName: speakerLabel(for: seg.speakerID, speakerNames: speakerNames),
                text: seg.text,
                pitchF0Hz: seg.embedding.map { ($0.f0Median * 10).rounded() / 10 }
            )
        }

        let payload = JSONExportPayload(
            fileName: mediaInfo?.fileName,
            durationSeconds: mediaInfo?.durationSeconds,
            segmentCount: items.count,
            segments: items
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(payload),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }

    // MARK: - CSV (.csv)

    private static func renderCSV(
        segments: [TranscriptSegment],
        speakerNames: [Int: String]
    ) -> String {
        var rows = ["Index,Start(s),End(s),TimeRange,SpeakerID,SpeakerName,PitchF0(Hz),Text"]
        for (idx, seg) in segments.enumerated() {
            let spk = escapeCSV(speakerLabel(for: seg.speakerID, speakerNames: speakerNames))
            let txt = escapeCSV(seg.text)
            let f0Str = seg.embedding.map { String(format: "%.1f", $0.f0Median) } ?? ""
            let row = String(
                format: "%d,%.2f,%.2f,\"%@\",%d,%@,%@,%@",
                idx + 1,
                seg.startTime,
                seg.endTime,
                seg.formattedTimeRange,
                seg.speakerID,
                spk,
                f0Str,
                txt
            )
            rows.append(row)
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func escapeCSV(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
