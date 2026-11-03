import Foundation

// MARK: - Review Model

enum SuggestionKind: String, Codable, Sendable {
    /// A term spelled wrongly everywhere (e.g. イスコン -> ISUCON), proposed by the local LLM
    case term
    /// Apple and Whisper heard different words at one place of an utterance
    case span
    /// The neural speaker model and the current acoustic model disagree on an utterance
    case speaker
}

enum SuggestionStatus: String, Codable, Sendable {
    case pending, accepted, rejected, edited
}

struct CorrectionSuggestion: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: SuggestionKind
    var status: SuggestionStatus
    /// span / speaker
    var segmentID: UUID?
    /// term: every utterance that contains `original`
    var segmentIDs: [UUID]?
    /// span: position of `original` in the utterance text (Unicode scalars)
    var offset: Int?
    var length: Int?
    var original: String?
    var candidate: String?
    /// The LLM picked the candidate (span) / proposed it (term)
    var recommended: Bool?
    var context: String?
    /// speaker: label assigned by the neural model and the alternative from the current model
    var current: Int?
    var alternative: Int?
    var note: String?
    /// Text the reviewer typed instead of either candidate
    var resolvedText: String?
}

struct RefinementReview: Decodable, Sendable {
    var segments: [TranscriptSegment]
    var suggestions: [CorrectionSuggestion]
    var autoAppliedTerms: [[String]]
    var timings: [String: Double]
}

// MARK: - Glossary (human-approved term dictionary)

struct GlossaryEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    var from: String
    var to: String
    var id: String { from + "\u{1F}" + to }
}

struct Glossary: Codable, Equatable, Sendable {
    var approved: [GlossaryEntry] = []
    var rejected: [GlossaryEntry] = []

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalSpeechSTT", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("glossary.json")
    }

    static func load() -> Glossary {
        guard let data = try? Data(contentsOf: fileURL),
              let glossary = try? JSONDecoder().decode(Glossary.self, from: data) else { return Glossary() }
        return glossary
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    mutating func approve(from: String, to: String) {
        let entry = GlossaryEntry(from: from, to: to)
        rejected.removeAll { $0.from == from && $0.to == to }
        approved.removeAll { $0.from == from }
        approved.append(entry)
    }

    mutating func reject(from: String, to: String) {
        let entry = GlossaryEntry(from: from, to: to)
        if !rejected.contains(entry) { rejected.append(entry) }
    }
}

// MARK: - Term Replacement

enum TermReplacer {
    /// Replaces `from` with `to`. Latin/digit edges only match at word boundaries, so "LL" never
    /// rewrites the inside of "LLMIPI" (the same rule as tools/refine/refine.py `term_pattern`).
    static func replace(_ from: String, with to: String, in text: String) -> String {
        guard !from.isEmpty, let regex = try? NSRegularExpression(pattern: pattern(for: from)) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: to))
    }

    static func occurrences(of from: String, in text: String) -> Int {
        guard !from.isEmpty, let regex = try? NSRegularExpression(pattern: pattern(for: from)) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func pattern(for from: String) -> String {
        var p = NSRegularExpression.escapedPattern(for: from)
        if let first = from.unicodeScalars.first, isLatinOrDigit(first) { p = "(?<![A-Za-z0-9])" + p }
        if let last = from.unicodeScalars.last, isLatinOrDigit(last) { p += "(?![A-Za-z0-9])" }
        return p
    }

    private static func isLatinOrDigit(_ s: Unicode.Scalar) -> Bool {
        (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9")
    }
}

// MARK: - Refinement Runner

enum RefinementError: LocalizedError {
    case toolsNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .toolsNotFound:
            return "補正ツール (tools/refine) が見つかりません。リポジトリの tools/refine を LocalSpeechSTT.app と同じ階層に置いてください。"
        case .failed(let message):
            return "高精度補正に失敗しました: \(message)"
        }
    }
}

/// Runs the local refinement pipeline (`tools/refine/refine.py`: Whisper + neural speaker embeddings
/// + Gemma) as a subprocess through the user's login shell, so that `uv` and `ffmpeg` are found
/// on the same PATH as in Terminal.
enum RefinementService {
    static func toolsDirectory() -> URL? {
        var candidates: [URL] = []
        if let custom = UserDefaults.standard.string(forKey: "refineToolsPath"), !custom.isEmpty {
            candidates.append(URL(fileURLWithPath: custom))
        }
        // LocalSpeechSTT.app lives in the repository root next to tools/
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("tools/refine"))
        // Development builds: <repo>/Sources/LocalSpeechSTT/RefinementService.swift
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tools/refine"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("refine.py").path) }
    }

    static func cacheDirectory(for media: URL) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalSpeechSTT/refine", isDirectory: true)
        let attrs = try? FileManager.default.attributesOfItem(atPath: media.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(media.path)|\(Int(stamp))".utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return base.appendingPathComponent(String(format: "%@-%016llx", media.deletingPathExtension().lastPathComponent, key))
    }

    static func run(
        media: URL,
        segments: [TranscriptSegment],
        speakerMode: SpeakerCountMode,
        glossary: Glossary,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> RefinementReview {
        guard let tools = toolsDirectory() else { throw RefinementError.toolsNotFound }
        let work = cacheDirectory(for: media)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let rawURL = work.appendingPathComponent("app_segments.json")
        let glossaryURL = work.appendingPathComponent("glossary.json")
        let outURL = work.appendingPathComponent("app_review.json")
        try? FileManager.default.removeItem(at: outURL)
        try JSONEncoder().encode(segments).write(to: rawURL)
        try JSONEncoder().encode(glossary).write(to: glossaryURL)

        let speakers: Int
        switch speakerMode {
        case .off: speakers = 0
        case .auto: speakers = -1
        default: speakers = speakerMode.rawValue
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc", #"cd "$1" && shift && exec uv run --quiet python refine.py "$@""#, "zsh",
            tools.path,
            "--raw", rawURL.path,
            "--media", media.path,
            "--work-dir", work.path,
            "--app-review", outURL.path,
            "--glossary", glossaryURL.path,
            "--speakers", String(speakers),
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        final class OutputBuffer: @unchecked Sendable {
            let lock = NSLock()
            var pending = ""
            var errorTail: [String] = []

            func lastError(fallback: String) -> String {
                lock.lock()
                defer { lock.unlock() }
                return errorTail.last(where: { !$0.contains("Warning") }) ?? fallback
            }
        }
        let buffer = OutputBuffer()

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            buffer.lock.lock()
            buffer.pending += chunk
            var lines = buffer.pending.components(separatedBy: "\n")
            buffer.pending = lines.removeLast()
            buffer.lock.unlock()
            for line in lines where line.hasPrefix("PROGRESS ") {
                let parts = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                if let first = parts.first, let fraction = Double(first) {
                    onProgress(fraction, parts.count > 1 ? String(parts[1]) : "")
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            buffer.lock.lock()
            buffer.errorTail.append(contentsOf: chunk.components(separatedBy: "\n").filter { !$0.isEmpty })
            buffer.errorTail = Array(buffer.errorTail.suffix(8))
            buffer.lock.unlock()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()

        guard process.terminationStatus == 0, let data = try? Data(contentsOf: outURL) else {
            throw RefinementError.failed(buffer.lastError(fallback: "終了コード \(process.terminationStatus)"))
        }
        do {
            return try JSONDecoder().decode(RefinementReview.self, from: data)
        } catch {
            throw RefinementError.failed("結果の読み込みエラー: \(error.localizedDescription)")
        }
    }
}
