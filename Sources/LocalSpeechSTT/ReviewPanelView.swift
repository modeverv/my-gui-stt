import SwiftUI

/// Local UI state of the review panel (kept in an ObservableObject: this toolchain has no @State macro plugin).
final class ReviewPanelState: ObservableObject {
    @Published var filter: ReviewPanelView.Filter = .all
    @Published var pendingOnly = true
    @Published var recommendedOnly = true
    @Published var manualFrom = ""
    @Published var manualTo = ""
    @Published var manualFeedback: String?
    /// The suggestion whose "自分で修正" field is open, and its text
    @Published var editingID: UUID?
    @Published var customText = ""
}

/// Human-in-the-loop review of the refinement suggestions: the reviewer confirms, rejects or
/// rewrites every candidate, and can point out errors the models missed.
struct ReviewPanelView: View {
    @ObservedObject var viewModel: AppViewModel

    enum Filter: String, CaseIterable, Identifiable {
        case all = "すべて"
        case term = "用語"
        case speaker = "話者"
        case span = "食い違い"
        var id: String { rawValue }
    }

    @StateObject private var ui = ReviewPanelState()

    private var visible: [CorrectionSuggestion] {
        viewModel.suggestions.filter { s in
            switch ui.filter {
            case .all: break
            case .term: if s.kind != .term { return false }
            case .speaker: if s.kind != .speaker { return false }
            case .span: if s.kind != .span { return false }
            }
            if ui.pendingOnly && s.status != .pending { return false }
            if ui.recommendedOnly && s.kind == .span && s.recommended != true { return false }
            return true
        }
        .sorted(by: AppViewModel.reviewOrder)
    }

    private func count(_ kind: SuggestionKind) -> Int {
        viewModel.suggestions.filter { $0.kind == kind && $0.status == .pending }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            manualCorrectionBar
            Divider()
            filterBar
            Divider()
            if viewModel.suggestions.isEmpty {
                emptyState
            } else if visible.isEmpty {
                Text(ui.pendingOnly ? "この条件の未対応の候補はありません" : "この条件の候補はありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(visible) { sug in
                            SuggestionRowView(viewModel: viewModel, ui: ui, suggestion: sug)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: Manual correction ("this is wrong, it should be ...")

    private var manualCorrectionBar: some View {
        let hits = viewModel.occurrenceCount(of: ui.manualFrom)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "hand.point.up.left")
                    .foregroundStyle(Color.accentColor)
                Text("誤りを指摘して直す")
                    .font(.subheadline.bold())
                TextField("誤 (例: オーパス)", text: $ui.manualFrom)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField("正 (例: Opus)", text: $ui.manualTo)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
                    .onSubmit(applyManual)
                Text(ui.manualFrom.isEmpty ? "" : "\(hits) 箇所")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(hits > 0 ? Color.primary : Color.secondary)
                    .frame(minWidth: 44, alignment: .leading)
                Button("全体に適用して辞書に登録", action: applyManual)
                    .disabled(hits == 0 || ui.manualTo.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            Text(ui.manualFeedback ?? "英字の語は単語の境界でだけ置換します (LL → LLM は LLMIPI の中を変えません)。登録した表記は次回の文字起こしにも使われます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func applyManual() {
        let n = viewModel.applyManualCorrection(from: ui.manualFrom, to: ui.manualTo)
        if n > 0 {
            ui.manualFeedback = "「\(ui.manualFrom)」→「\(ui.manualTo)」を \(n) 箇所に適用し、用語辞書に登録しました (下の一覧から取り消せます)"
            ui.manualFrom = ""
            ui.manualTo = ""
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("種類", selection: $ui.filter) {
                Text("すべて (\(viewModel.pendingSuggestionCount))").tag(Filter.all)
                Text("用語 (\(count(.term)))").tag(Filter.term)
                Text("話者 (\(count(.speaker)))").tag(Filter.speaker)
                Text("食い違い (\(count(.span)))").tag(Filter.span)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            Toggle("未対応のみ", isOn: $ui.pendingOnly)
                .toggleStyle(.checkbox)
            Toggle("LLM が推奨した食い違いのみ", isOn: $ui.recommendedOnly)
                .toggleStyle(.checkbox)
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("上部の「高精度補正」を実行すると、ここに補正候補が並びます")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Whisper との食い違い・話者判定の食い違い・ローカル LLM が見つけた用語の誤りを、1件ずつ確定できます。\n候補に無い誤りは、上の欄から直接指摘できます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - One Suggestion

struct SuggestionRowView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var ui: ReviewPanelState
    let suggestion: CorrectionSuggestion

    private var editing: Bool { ui.editingID == suggestion.id }

    private var segment: TranscriptSegment? {
        viewModel.segment(withID: suggestion.segmentID ?? suggestion.segmentIDs?.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
            actions
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(suggestion.status == .pending ? Color(NSColor.controlBackgroundColor) : Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(suggestion.status == .pending ? Color.secondary.opacity(0.2) : statusColor.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(kindLabel)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(kindColor.opacity(0.15))
                .foregroundStyle(kindColor)
                .clipShape(Capsule())
            if let seg = segment {
                Button {
                    viewModel.playerManager.seek(to: max(0, seg.startTime - 0.5), autoPlay: true)
                } label: {
                    Label(TimeFormatter.format(seg.startTime, includeMillis: false), systemImage: "play.fill")
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.borderless)
                .help("この位置から再生")
            }
            if suggestion.kind == .term, let n = suggestion.segmentIDs?.count {
                Text("\(n) 発話に出現").font(.caption).foregroundStyle(.secondary)
            }
            if suggestion.recommended == true && suggestion.kind == .span {
                Text("LLM 推奨: 候補B")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.purple)
            }
            if let note = suggestion.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if suggestion.status != .pending {
                Text(statusLabel)
                    .font(.caption.bold())
                    .foregroundStyle(statusColor)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch suggestion.kind {
        case .term:
            HStack(spacing: 8) {
                Text(suggestion.original ?? "").strikethrough(color: .secondary)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(suggestion.resolvedText ?? suggestion.candidate ?? "").fontWeight(.semibold)
            }
            .font(.title3)
            if let seg = segment {
                Text(highlighted(seg.text, term: suggestion.status == .pending ? suggestion.original : (suggestion.resolvedText ?? suggestion.candidate)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        case .span:
            if let seg = segment {
                Text(highlighted(seg.text, term: suggestion.status == .pending ? suggestion.original : (suggestion.resolvedText ?? suggestion.candidate)))
                    .font(.callout)
                    .textSelection(.enabled)
            }
            HStack(spacing: 16) {
                Label("A (Apple): \(suggestion.original ?? "")", systemImage: "a.circle")
                Label("B (Whisper): \(suggestion.candidate ?? "")", systemImage: "b.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .speaker:
            if let seg = segment {
                Text(seg.text).font(.callout).lineLimit(3)
            }
            HStack(spacing: 8) {
                speakerTag(suggestion.current ?? 1, prefix: "ニューラル判定")
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                speakerTag(suggestion.alternative ?? 1, prefix: "別の候補")
            }
            .font(.caption)
        }
    }

    private func speakerTag(_ id: Int, prefix: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(SpeakerInfo.color(for: id)).frame(width: 8, height: 8)
            Text("\(prefix): \(viewModel.speakerDisplayName(for: id))")
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if suggestion.status == .pending {
            HStack(spacing: 8) {
                Button(acceptLabel) { viewModel.acceptSuggestion(suggestion.id) }
                    .buttonStyle(.borderedProminent)
                Button(rejectLabel) { viewModel.rejectSuggestion(suggestion.id) }
                if suggestion.kind != .speaker {
                    if editing {
                        TextField("正しい表記", text: $ui.customText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                            .onSubmit(acceptCustom)
                        Button("これで確定", action: acceptCustom)
                            .disabled(ui.customText.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Button("自分で修正...") {
                            ui.customText = suggestion.candidate ?? ""
                            ui.editingID = suggestion.id
                        }
                    }
                }
                Spacer()
            }
            .controlSize(.small)
        } else {
            HStack {
                Button("取り消す") { viewModel.undoSuggestion(suggestion.id) }
                    .controlSize(.small)
                Spacer()
            }
        }
    }

    private func acceptCustom() {
        let text = ui.customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.acceptSuggestion(suggestion.id, customText: text)
        ui.editingID = nil
    }

    // MARK: Labels

    private var kindLabel: String {
        switch suggestion.kind {
        case .term: return "用語"
        case .span: return "食い違い"
        case .speaker: return "話者"
        }
    }

    private var kindColor: Color {
        switch suggestion.kind {
        case .term: return .orange
        case .span: return .purple
        case .speaker: return .teal
        }
    }

    private var acceptLabel: String {
        switch suggestion.kind {
        case .term: return "全体に適用 (辞書に登録)"
        case .span: return "B を採用"
        case .speaker: return "\(viewModel.speakerDisplayName(for: suggestion.alternative ?? 1)) に変更"
        }
    }

    private var rejectLabel: String {
        switch suggestion.kind {
        case .term: return "却下 (今後も提案しない)"
        case .span: return "A のまま"
        case .speaker: return "このまま"
        }
    }

    private var statusLabel: String {
        switch suggestion.status {
        case .accepted: return "採用"
        case .edited: return "修正して採用"
        case .rejected: return "却下"
        case .pending: return ""
        }
    }

    private var statusColor: Color {
        switch suggestion.status {
        case .accepted, .edited: return .green
        case .rejected: return .secondary
        case .pending: return .clear
        }
    }

    private func highlighted(_ text: String, term: String?) -> AttributedString {
        var attr = AttributedString(text)
        if let term, !term.isEmpty, let range = attr.range(of: term) {
            attr[range].backgroundColor = Color.yellow.opacity(0.45)
            attr[range].foregroundColor = Color.primary
        }
        return attr
    }
}
