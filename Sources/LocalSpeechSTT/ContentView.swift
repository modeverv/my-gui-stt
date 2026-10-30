import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HSplitView {
            // MARK: - Left Sidebar (Controls, Player, Settings, Speakers)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fileDropSection
                    if viewModel.mediaInfo != nil {
                        mediaPlayerSection
                    }
                    sttSettingsSection
                    speakerDiarizationSection
                }
                .padding(14)
            }
            .frame(minWidth: 330, idealWidth: 360, maxWidth: 420)
            .background(Color(NSColor.windowBackgroundColor))

            // MARK: - Right Main Area (Progress, Toolbar, Transcript, Export)
            VStack(spacing: 0) {
                topExecutionBar
                Divider()
                filterAndViewToolbar
                Divider()

                if let err = viewModel.errorMessage {
                    errorBanner(message: err)
                }

                if viewModel.isTranscribing && !viewModel.volatilePreviewText.isEmpty {
                    volatileLiveBanner
                }

                mainTranscriptArea

                Divider()
                bottomExportBar
            }
            .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
            handleFileDrop(providers: providers)
        }
        .overlay {
            if viewModel.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "waveform.badge.plus")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.accentColor)
                            Text("動画・音声ファイルをここにドロップして読み込む")
                                .font(.title3.bold())
                        }
                    }
                    .padding(12)
            }
        }
    }

    // MARK: - 1. File Selection & Drop Card

    private var fileDropSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("メディアファイル", systemImage: "film.stack")
                        .font(.headline)
                    Spacer()
                    Text("完全ローカル処理")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.18))
                        .foregroundStyle(Color.green)
                        .clipShape(Capsule())
                }

                Button {
                    viewModel.openFilePicker()
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text("動画・音声ファイルを選択...")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let info = viewModel.mediaInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: info.hasVideo ? "video.fill" : "waveform")
                                .foregroundStyle(Color.accentColor)
                            Text(info.fileName)
                                .font(.subheadline.bold())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        HStack(spacing: 8) {
                            Label(info.formattedDuration, systemImage: "clock")
                            Text("•")
                            Text(info.formattedFileSize)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(info.formatSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("対応形式: MP4, MOV, M4V, M4A, MP3, WAV, AAC, FLAC, AIFF, CAF 等 (ドラッグ&ドロップ対応)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - 2. Media Player & Waveform Card

    private var mediaPlayerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("プレビュー再生", systemImage: "play.circle")
                        .font(.headline)
                    Spacer()
                    Picker("速度", selection: Binding(
                        get: { viewModel.playerManager.playbackRate },
                        set: { viewModel.playerManager.setRate($0) }
                    )) {
                        Text("0.75x").tag(Float(0.75))
                        Text("1.0x").tag(Float(1.0))
                        Text("1.25x").tag(Float(1.25))
                        Text("1.5x").tag(Float(1.5))
                        Text("2.0x").tag(Float(2.0))
                    }
                    .pickerStyle(.menu)
                    .frame(width: 85)
                    .controlSize(.small)
                }

                if viewModel.mediaInfo?.hasVideo == true {
                    NativeVideoPlayerView(player: viewModel.playerManager.player)
                        .frame(height: 175)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Interactive Waveform Seek Bar
                WaveformTimelineView(
                    peaks: viewModel.waveformPeaks,
                    currentTime: viewModel.playerManager.currentTime,
                    duration: max(0.1, viewModel.playerManager.duration)
                ) { seekSeconds in
                    viewModel.playerManager.seek(to: seekSeconds)
                }
                .frame(height: 44)

                HStack(spacing: 10) {
                    Button {
                        viewModel.playerManager.seek(to: viewModel.playerManager.currentTime - 5.0)
                    } label: {
                        Image(systemName: "gobackward.5")
                    }
                    .buttonStyle(.borderless)
                    .help("5秒戻る")

                    Button {
                        viewModel.playerManager.togglePlayPause()
                    } label: {
                        Image(systemName: viewModel.playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button {
                        viewModel.playerManager.seek(to: viewModel.playerManager.currentTime + 5.0)
                    } label: {
                        Image(systemName: "goforward.5")
                    }
                    .buttonStyle(.borderless)
                    .help("5秒進む")

                    Spacer()

                    Text("\(TimeFormatter.format(viewModel.playerManager.currentTime, includeMillis: false)) / \(TimeFormatter.format(viewModel.playerManager.duration, includeMillis: false))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - 3. STT Engine & Language Settings Card

    private var sttSettingsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Apple 音声認識エンジン設定", systemImage: "cpu")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("STTエンジン")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker("STTエンジン", selection: $viewModel.selectedEngine) {
                        ForEach(TranscriptionEngineType.allCases) { eng in
                            Text(eng.displayName).tag(eng)
                        }
                    }
                    .labelsHidden()
                    Text(viewModel.selectedEngine.shortDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("認識言語 (オンデバイスモデル)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker("言語", selection: $viewModel.selectedLocaleID) {
                        ForEach(viewModel.availableLocales) { item in
                            Text(item.labelWithStatus).tag(item.identifier)
                        }
                    }
                    .labelsHidden()
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("発話区切り無音時間")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f 秒", viewModel.pauseThresholdSeconds))
                            .font(.system(.caption, design: .monospaced))
                    }
                    Slider(value: $viewModel.pauseThresholdSeconds, in: 0.20...1.80, step: 0.05)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("専門用語・固有名詞ヒント (カンマ/改行区切り)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    TextField("例: 議事録, プロジェクト名, 人名...", text: $viewModel.customVocabularyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                }
            }
            .padding(4)
        }
        .disabled(viewModel.isTranscribing)
    }

    // MARK: - 4. Speaker Diarization & Speaker Rename Card

    private var speakerDiarizationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("話者分離 (Speaker Diarization)", systemImage: "person.2.wave.2")
                        .font(.headline)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("話者数モード (変更すると即座に再分離します)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Picker("話者数", selection: $viewModel.speakerMode) {
                        ForEach(SpeakerCountMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                }

                if viewModel.speakerMode != .off && !viewModel.detectedSpeakers.isEmpty {
                    Divider()
                    Text("検出された話者 (名前を編集可能)")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(viewModel.detectedSpeakers) { spk in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(SpeakerInfo.color(for: spk.id))
                                    .frame(width: 10, height: 10)

                                TextField(
                                    "話者 \(spk.id)",
                                    text: Binding(
                                        get: { viewModel.speakerNames[spk.id] ?? "話者 \(spk.id)" },
                                        set: { viewModel.updateSpeakerName(speakerID: spk.id, newName: $0) }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                                .frame(width: 110)

                                Spacer()

                                if let f0 = spk.averageF0 {
                                    Text(String(format: "%.0fHz", f0))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .help("平均基本周波数 (声の高さ)")
                                }

                                Text("\(spk.segmentCount)件 • \(TimeFormatter.format(spk.totalDuration, includeMillis: false))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    // MARK: - Right Top Execution Bar

    private var topExecutionBar: some View {
        HStack(spacing: 14) {
            if viewModel.isTranscribing {
                Button(role: .destructive) {
                    viewModel.cancelTranscription()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                        Text("停止")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button {
                    viewModel.startTranscription()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.and.mic")
                        Text(viewModel.segments.isEmpty ? "文字起こし開始 (STT実行)" : "再実行 (STT)")
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.mediaInfo == nil)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(viewModel.statusMessage)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    if viewModel.processingSpeedMultiplier > 0.1 {
                        Text(String(format: "%.1fx 倍速", viewModel.processingSpeedMultiplier))
                            .font(.system(.caption, design: .monospaced).bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                    if viewModel.isTranscribing {
                        Text(String(format: "%.0f%%", viewModel.progressFraction * 100))
                            .font(.system(.caption, design: .monospaced).bold())
                    }
                }

                ProgressView(value: viewModel.progressFraction, total: 1.0)
                    .progressViewStyle(.linear)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Right Filter & View Mode Toolbar

    private var filterAndViewToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Picker("表示モード", selection: $viewModel.viewMode) {
                    ForEach(TranscriptViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("キーワード・話者・時間で検索...", text: $viewModel.searchQuery)
                        .textFieldStyle(.plain)
                    if !viewModel.searchQuery.isEmpty {
                        Button {
                            viewModel.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(NSColor.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .frame(maxWidth: 260)

                Spacer()

                Toggle("タイムスタンプ", isOn: $viewModel.showTimestamps)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                if viewModel.speakerMode != .off {
                    Toggle("話者ラベル", isOn: $viewModel.showSpeakers)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }

                Toggle("同一話者を結合", isOn: $viewModel.mergeConsecutiveSameSpeaker)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            // Speaker Filter Pills
            if viewModel.speakerMode != .off && viewModel.detectedSpeakers.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("話者フィルタ:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            viewModel.selectedSpeakerFilter = nil
                        } label: {
                            Text("すべて (\(viewModel.segments.count))")
                                .font(.caption.weight(viewModel.selectedSpeakerFilter == nil ? .bold : .regular))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(viewModel.selectedSpeakerFilter == nil ? Color.accentColor : Color.secondary.opacity(0.15))
                                .foregroundStyle(viewModel.selectedSpeakerFilter == nil ? Color.white : Color.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(viewModel.detectedSpeakers) { spk in
                            let isSelected = viewModel.selectedSpeakerFilter == spk.id
                            let spkColor = SpeakerInfo.color(for: spk.id)
                            Button {
                                viewModel.selectedSpeakerFilter = isSelected ? nil : spk.id
                            } label: {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(isSelected ? Color.white : spkColor)
                                        .frame(width: 7, height: 7)
                                    Text("\(spk.name) (\(spk.segmentCount))")
                                        .font(.caption.weight(isSelected ? .bold : .regular))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isSelected ? spkColor : spkColor.opacity(0.14))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Banners

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
            Spacer()
            Button("閉じる") {
                viewModel.errorMessage = nil
            }
            .buttonStyle(.plain)
            .font(.caption.bold())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.88))
    }

    private var volatileLiveBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("リアルタイム認識中:")
                .font(.caption.bold())
                .foregroundStyle(Color.accentColor)
            Text(viewModel.volatilePreviewText)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Main Transcript Area

    @ViewBuilder
    private var mainTranscriptArea: some View {
        if viewModel.segments.isEmpty && !viewModel.isTranscribing {
            emptyStatePlaceholder
        } else {
            switch viewModel.viewMode {
            case .timeline:
                timelineSegmentListView
            case .fullText:
                fullTextPreviewView
            }
        }
    }

    private var emptyStatePlaceholder: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(viewModel.mediaInfo == nil ? "左側のパネルから動画・音声ファイルを選択するか、ここにドラッグ＆ドロップしてください" : "上部の「文字起こし開始 (STT実行)」ボタンを押すとローカルで文字起こしを開始します")
                .font(.headline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("Apple SpeechAnalyzer / SpeechTranscriber オンデバイスエンジン • タイムスタンプ • ローカル話者分離対応")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timelineSegmentListView: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(viewModel.filteredSegments) { segment in
                    SegmentRowView(
                        segment: segment,
                        speakerName: viewModel.speakerDisplayName(for: segment.speakerID),
                        showTimestamp: viewModel.showTimestamps,
                        showSpeaker: viewModel.showSpeakers && viewModel.speakerMode != .off,
                        isPlayingCurrent: viewModel.activePlayingSegmentID == segment.id,
                        isEditable: !viewModel.mergeConsecutiveSameSpeaker,
                        availableSpeakerIDs: max(6, (viewModel.detectedSpeakers.map(\.id).max() ?? 2)),
                        speakerNameLookup: { viewModel.speakerDisplayName(for: $0) },
                        onSeekPlay: {
                            viewModel.playerManager.seek(to: segment.startTime, autoPlay: true)
                        },
                        onChangeSpeaker: { newSpk in
                            viewModel.updateSegmentSpeaker(segmentID: segment.id, newSpeakerID: newSpk)
                        },
                        onChangeText: { newTxt in
                            viewModel.updateSegmentText(segmentID: segment.id, newText: newTxt)
                        }
                    )
                    .id(segment.id)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }
            .listStyle(.plain)
            .onChange(of: viewModel.activePlayingSegmentID) { _, newID in
                if let id = newID, viewModel.playerManager.isPlaying {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private var fullTextPreviewView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("プレビュー形式:")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Picker("形式", selection: $viewModel.previewExportFormat) {
                    ForEach(ExportFormat.allCases) { fmt in
                        Text(fmt.displayName).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 620)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            ScrollView {
                Text(viewModel.formattedFullTextPreview)
                    .font(.system(.body, design: viewModel.previewExportFormat == .txt || viewModel.previewExportFormat == .markdown ? .default : .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
    }

    // MARK: - Bottom Export & Summary Bar

    private var bottomExportBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Label("\(viewModel.filteredSegments.count) セグメント", systemImage: "list.number")
                Label("\(viewModel.totalCharacterCount) 文字", systemImage: "character.cursor.ibeam")
                if viewModel.speakerMode != .off && !viewModel.detectedSpeakers.isEmpty {
                    Label("\(viewModel.detectedSpeakers.count) 話者", systemImage: "person.2")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let banner = viewModel.copyFeedbackBanner {
                Text(banner)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.2))
                    .foregroundStyle(Color.green)
                    .clipShape(Capsule())
            }

            Spacer()

            Button {
                viewModel.copyTranscriptToClipboard()
            } label: {
                Label("クリップボードにコピー", systemImage: "doc.on.doc")
            }
            .disabled(viewModel.segments.isEmpty)

            Menu {
                ForEach(ExportFormat.allCases) { fmt in
                    Button {
                        viewModel.exportTranscriptToFile(format: fmt)
                    } label: {
                        Text(fmt.displayName)
                    }
                }
            } label: {
                Label("ファイルに保存...", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.segments.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Drop Helper

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let fileURL: URL?
            if let data = item as? Data {
                fileURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                fileURL = url
            } else {
                fileURL = nil
            }
            if let validURL = fileURL {
                Task { @MainActor in
                    await viewModel.loadMediaFile(url: validURL)
                }
            }
        }
        return true
    }
}

// MARK: - Individual Segment Row Component

struct SegmentRowView: View {
    let segment: TranscriptSegment
    let speakerName: String
    let showTimestamp: Bool
    let showSpeaker: Bool
    let isPlayingCurrent: Bool
    let isEditable: Bool
    let availableSpeakerIDs: Int
    let speakerNameLookup: (Int) -> String
    let onSeekPlay: () -> Void
    let onChangeSpeaker: (Int) -> Void
    let onChangeText: (String) -> Void

    private var textBinding: Binding<String> {
        Binding(
            get: { segment.text },
            set: { newValue in
                if newValue != segment.text {
                    onChangeText(newValue)
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Play / Timestamp button
            Button(action: onSeekPlay) {
                HStack(spacing: 4) {
                    Image(systemName: isPlayingCurrent ? "speaker.wave.2.fill" : "play.fill")
                        .font(.caption2)
                    if showTimestamp {
                        Text(segment.formattedTimeRange)
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(isPlayingCurrent ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(isPlayingCurrent ? Color.white : Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("クリックしてこの位置 (\(segment.formattedTimeRange)) から再生")

            // Speaker Badge Menu
            if showSpeaker {
                let spkColor = SpeakerInfo.color(for: segment.speakerID)
                Menu {
                    ForEach(1...availableSpeakerIDs, id: \.self) { spkID in
                        Button {
                            onChangeSpeaker(spkID)
                        } label: {
                            HStack {
                                Text(speakerNameLookup(spkID))
                                if spkID == segment.speakerID {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(spkColor)
                            .frame(width: 8, height: 8)
                        Text(speakerName)
                            .font(.caption.bold())
                            .foregroundStyle(spkColor)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(spkColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("クリックしてこの発話の話者を変更")
            }

            // Editable or static transcript text
            if isEditable {
                TextField("発話テキスト", text: textBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .padding(.vertical, 2)
            } else {
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPlayingCurrent ? Color.accentColor.opacity(0.09) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPlayingCurrent ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.15), lineWidth: isPlayingCurrent ? 1.5 : 1)
        )
    }
}

// MARK: - Interactive Waveform Timeline View

struct WaveformTimelineView: View {
    let peaks: [Float]
    let currentTime: Double
    let duration: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let height = max(1, geo.size.height)
            let progress = duration > 0 ? min(1.0, max(0.0, currentTime / duration)) : 0.0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(NSColor.textBackgroundColor))

                if peaks.isEmpty {
                    // Fallback bar if waveform is still loading
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: width * progress, height: 6)
                } else {
                    HStack(alignment: .center, spacing: 1.5) {
                        ForEach(peaks.indices, id: \.self) { idx in
                            let frac = Double(idx) / Double(max(1, peaks.count))
                            let isPlayed = frac <= progress
                            let barHeight = max(3, CGFloat(peaks[idx]) * (height - 8))
                            RoundedRectangle(cornerRadius: 1)
                                .fill(isPlayed ? Color.accentColor : Color.secondary.opacity(0.35))
                                .frame(height: barHeight)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                // Playhead line
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: height)
                    .offset(x: min(width - 2, max(0, width * progress)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(1.0, max(0.0, Double(value.location.x / width)))
                        onSeek(ratio * duration)
                    }
            )
        }
    }
}
