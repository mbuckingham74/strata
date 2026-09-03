import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

// MARK: - M7 Strata design notes
//
// Representation: six visually stacked strata sharing one horizontal timeline.
// - Display order is fixed: Vocals, Drums, Bass, Guitar, Piano, Other
//   (not alphabetical sortedStems). Defined by `strataDisplayOrder`.
// - Timeline alignment: every row's waveform occupies the same flex width.
//   Left label column (148pt) and right control columns (gain 118pt, audibility 136pt) are fixed,
//   so GeometryReader-derived waveform widths are identical across rows.
//   The shared ruler at the top uses the identical HStack insets, so its
//   ticks line up with waveforms. Waveform is flex (maxWidth: .infinity) and
//   shrinks to fund the wider fixed columns, preserving height 52 and 6-row density.
// - Playhead: vertical line at currentTime/duration rendered inside each
//   waveform's ZStack at the same fractional x. Because widths match, the
//   line visually reads as continuous across strata.
// - Waveform: real peaks from AVFoundation via `WaveformProvider` (no fake).
// - Transport: uses existing `StemPlaybackController.duration/currentTime`
//   and `seek(to:)`. Both ruler and waveform areas support tap/drag to seek.

let strataDisplayOrder: [StemName] = [.vocals, .drums, .bass, .guitar, .piano, .other]

// Distinct but muted tints per stem — cohesive dark theme
private func strataColor(for stem: StemName) -> Color {
    switch stem {
    case .vocals: return Color(red: 0.56, green: 0.46, blue: 0.95) // purple
    case .drums: return Color(red: 0.96, green: 0.55, blue: 0.45) // coral
    case .bass: return Color(red: 0.38, green: 0.68, blue: 0.92) // sky
    case .guitar: return Color(red: 0.45, green: 0.82, blue: 0.58) // mint
    case .piano: return Color(red: 0.95, green: 0.78, blue: 0.45) // amber
    case .other: return Color(nsColor: .secondaryLabelColor)
    }
}

private func strataIcon(for stem: StemName) -> String {
    switch stem {
    case .vocals: return "mic.fill"
    case .drums: return "metronome.fill"
    case .bass: return "guitars.fill"
    case .guitar: return "guitars"
    case .piano: return "pianokeys"
    case .other: return "music.note"
    }
}

// MARK: - WaveformView (real data)

struct WaveformView: View {
    let url: URL
    let color: Color
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onSeek: (Double) -> Void
    var isMuted: Bool = false

    @State private var samples: [Float]? = nil
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let fraction: CGFloat = duration > 0 ? CGFloat(min(max(currentTime / duration, 0), 1)) : 0
            let playheadX = fraction * w

            ZStack(alignment: .leading) {
                // Track background — slightly darker when muted so dimmed waveform still reads as a track
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isMuted ? 0.03 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                if let samples, !samples.isEmpty {
                    Canvas { context, size in
                        let count = samples.count
                        guard count > 0, size.width > 0, size.height > 0 else { return }
                        let centerY = size.height / 2
                        let barWidth = size.width / CGFloat(count)
                        let minBarW: CGFloat = 1.1
                        for (i, amp) in samples.enumerated() {
                            let x = CGFloat(i) * barWidth
                            let barH = CGFloat(amp) * size.height * 0.92
                            let rect = CGRect(
                                x: x + barWidth * 0.12,
                                y: centerY - barH / 2,
                                width: max(barWidth * 0.74, minBarW),
                                height: max(barH, 1.4)
                            )
                            let path = Path(roundedRect: rect, cornerRadius: 1.2)
                            context.fill(path, with: .color(color.opacity(0.92)))
                        }
                    }
                } else if isLoading {
                    HStack { Spacer(); ProgressView().scaleEffect(0.55).tint(.secondary); Spacer() }
                } else {
                    // Empty but not loading: thin midline so alignment still reads as a stratum
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).frame(maxHeight: .infinity, alignment: .center)
                }

                // Vertical playhead — 1pt line + dot
                if duration > 0 {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 1.2, height: h)
                        .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 0)
                        .offset(x: playheadX)
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                        .shadow(color: color.opacity(0.5), radius: 3)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        .offset(x: playheadX - 3.5, y: -h / 2 + 5)
                        .offset(y: h / 2)
                }
            }
            // Seek gesture — tap/drag anywhere on waveform to seek
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard w > 0 else { return }
                        let f = min(max(value.location.x / w, 0), 1)
                        onSeek(Double(f))
                    }
                    .onEnded { value in
                        guard w > 0 else { return }
                        let f = min(max(value.location.x / w, 0), 1)
                        onSeek(Double(f))
                    }
            )
        }
        .task(id: url) {
            isLoading = true
            let s = await WaveformProvider.shared.load(url: url, targetCount: 220)
            samples = s
            isLoading = false
        }
    }
}

// MARK: - Ruler

struct StrataRulerView: View {
    let duration: TimeInterval
    let currentTime: TimeInterval
    let onSeek: (Double) -> Void

    private var tickCount: Int {
        if duration <= 30 { return 4 }
        if duration <= 90 { return 6 }
        if duration <= 180 { return 7 }
        return 8
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fraction: CGFloat = duration > 0 ? CGFloat(min(max(currentTime / duration, 0), 1)) : 0
            ZStack(alignment: .leading) {
                // Ticks + labels
                HStack(spacing: 0) {
                    ForEach(0..<tickCount, id: \.self) { idx in
                        let f = tickCount == 1 ? 0 : Double(idx) / Double(tickCount - 1)
                        let t = duration * f
                        VStack(alignment: .leading, spacing: 3) {
                            Rectangle().fill(Color.primary.opacity(0.22)).frame(width: 1, height: 8)
                            Text(StemPlaybackController.formattedTime(t))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Ruler playhead (thin line)
                if duration > 0 {
                    Rectangle().fill(Color.primary.opacity(0.45)).frame(width: 1, height: geo.size.height).offset(x: fraction * w)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard w > 0 else { return }
                        onSeek(Double(min(max(v.location.x / w, 0), 1)))
                    }
                    .onEnded { v in
                        guard w > 0 else { return }
                        onSeek(Double(min(max(v.location.x / w, 0), 1)))
                    }
            )
        }
    }
}

// MARK: - Single stratum row

struct StratumRowView: View {
    let artifact: StemArtifact
    @Bindable var stemPlaybackController: StemPlaybackController
    var onExport: (StemArtifact, StemExportFormat) -> Void
    var isMp3ExportReady: Bool = true
    var isExporting: Bool = false
    var isExportReady: Bool { isMp3ExportReady }

    private var color: Color { strataColor(for: artifact.name) }
    private var isMuted: Bool { stemPlaybackController.mutedStems.contains(artifact.name) }

    var body: some View {
        HStack(spacing: 10) {
            // Left: stem identity — slightly dim when explicitly muted (not disabled row)
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(isMuted ? 0.14 : 0.18))
                        .frame(width: 26, height: 26)
                    Image(systemName: strataIcon(for: artifact.name))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(isMuted ? 0.86 : 1))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.name.rawValue.capitalized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(isMuted ? 0.84 : 1))
                        .lineLimit(1)
                }
            }
            .frame(width: 148, alignment: .leading)
            .opacity(isMuted ? 0.84 : 1)
            .saturation(isMuted ? 0.85 : 1)
            .animation(.easeInOut(duration: 0.18), value: isMuted)

            // Center: waveform (flex — identical width across rows ensures timeline alignment)
            WaveformView(
                url: artifact.url,
                color: color,
                duration: stemPlaybackController.duration,
                currentTime: stemPlaybackController.currentTime,
                onSeek: { fraction in
                    let t = fraction * stemPlaybackController.duration
                    stemPlaybackController.seek(to: t)
                },
                isMuted: isMuted
            )
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .opacity(isMuted ? 0.42 : 1)
            .saturation(isMuted ? 0.10 : 1)
            .animation(.easeInOut(duration: 0.18), value: isMuted)

            // Per-stem gain slider (0% silent .. 100% original, live, separate from mute/solo)
            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { stemPlaybackController.gainPercent(for: artifact.name) },
                        set: { stemPlaybackController.setGainPercent($0, for: artifact.name) }
                    ),
                    in: 0...100,
                    step: 1
                )
                .tint(color)
                .accessibilityIdentifier("GainSlider-\(artifact.name.rawValue)")
                .disabled(!stemPlaybackController.hasStems)
                Text("\(Int(stemPlaybackController.gainPercent(for: artifact.name).rounded()))%")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 118)

            // Audibility controls (preserve existing mute/solo)
            StemAudibilityControls(stemPlaybackController: stemPlaybackController, stem: artifact.name)
                .frame(width: 136)

            // Export per stem — WAV does not require FFmpeg, MP3 does
            Menu {
                Button("WAV") { onExport(artifact, .wav) }
                Button("MP3") { onExport(artifact, .mp3) }
                    .disabled(!isMp3ExportReady)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityIdentifier("ExportStem-\(artifact.name.rawValue)")
            .disabled(isExporting)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// MARK: - Stacked strata (shared timeline)

struct StrataStackView: View {
    let result: SeparationResult
    @Bindable var stemPlaybackController: StemPlaybackController
    @Bindable var inferenceController: InferenceController

    @AppStorage("mp3Quality") private var mp3Quality: MP3Quality = .highVBR

    @State private var exportErrorMessage: String?
    @State private var exportingFileName: String?
    @State private var savedFileName: String?
    private var isExporting: Bool { exportingFileName != nil }
    @State private var strataSliderValue: Double = 0
    @State private var isStrataDragging: Bool = false

    private var orderedStems: [StemArtifact] {
        strataDisplayOrder.compactMap { result.stems[$0] }
    }

    var effectiveDisplayTitle: String {
        // Preserve local behavior: local sources must show jobDirectoryURL.path exactly as before.
        // YouTube sources have human-readable metadata available via InferenceController state.
        let isYouTubeSource: Bool = {
            if let base = inferenceController.exportBaseName, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            if inferenceController.youTubeExportMetadata != nil {
                return true
            }
            if inferenceController.youTubeExportArtworkURL != nil {
                return true
            }
            let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !editable.isEmpty { return true }
            return false
        }()
        if isYouTubeSource {
            if let base = inferenceController.exportBaseName, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return base
            }
            let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !editable.isEmpty { return editable }
            if let t = stemPlaybackController.title, !t.isEmpty { return t }
            let fallback = result.inputURL.deletingPathExtension().lastPathComponent
            if !fallback.isEmpty && fallback != "/" { return fallback }
            return result.jobId.isEmpty ? result.jobDirectoryURL.lastPathComponent : result.jobId
        } else {
            return result.jobDirectoryURL.path
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MARK: - Global mixer transport — unmissable unified surface directly above 6 strata
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        if stemPlaybackController.isPlaying {
                            stemPlaybackController.pause()
                        } else {
                            stemPlaybackController.play()
                        }
                    } label: {
                        Image(systemName: stemPlaybackController.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 44, height: 44)
                            .background(Color.primary, in: Circle())
                            .shadow(color: Color.black.opacity(0.22), radius: 8, y: 3)
                            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!stemPlaybackController.hasStems)
                    .accessibilityLabel(stemPlaybackController.isPlaying ? "Pause strata" : "Play strata")
                    .accessibilityIdentifier("StrataPlayPause")

                    Button {
                        stemPlaybackController.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(Color.primary.opacity(0.10), in: Circle())
                            .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!stemPlaybackController.hasStems)
                    .accessibilityLabel("Stop strata")
                    .accessibilityIdentifier("StrataStop")
                    .help("Stop and return to start")

                    VStack(alignment: .leading, spacing: 2) {
                        Label("Strata — 6 layers", systemImage: "square.stack.3d.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text("\(stemPlaybackController.formattedCurrentTime) / \(stemPlaybackController.formattedDuration)")
                            .font(.callout.monospacedDigit().weight(.medium))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                    }

                    Spacer()

                    HStack(spacing: 6) {
                        Circle().fill(stemPlaybackController.isPlaying ? Color.green : Color.secondary.opacity(0.45)).frame(width: 6, height: 6)
                        Text(stemPlaybackController.isPlaying ? "Playing" : "Paused")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(stemPlaybackController.hasStems ? 1 : 0.45)
                }
                .padding(.horizontal, 12)

                // ONE obvious seek surface — full-width slider aligned to waveform column
                HStack(spacing: 10) {
                    Spacer().frame(width: 148)
                    Slider(
                        value: Binding(
                            get: { isStrataDragging ? strataSliderValue : stemPlaybackController.currentTime },
                            set: { strataSliderValue = $0 }
                        ),
                        in: 0...(stemPlaybackController.duration > 0 ? stemPlaybackController.duration : 1),
                        onEditingChanged: { editing in
                            isStrataDragging = editing
                            if editing {
                                strataSliderValue = stemPlaybackController.currentTime
                            } else {
                                stemPlaybackController.seek(to: strataSliderValue)
                            }
                        }
                    )
                    .tint(Color.primary)
                    .disabled(!stemPlaybackController.hasStems)
                    .accessibilityLabel("Seek strata")
                    .accessibilityIdentifier("StrataSeekSlider")

                    Spacer().frame(width: 118)
                    Spacer().frame(width: 136)
                    Color.clear.frame(width: 26, height: 20)
                }
                .padding(.horizontal, 10)

                // Shared ruler ticks — same insets, tap/drag to seek preserved (not a second Slider)
                HStack(spacing: 10) {
                    Spacer().frame(width: 148)
                    StrataRulerView(
                        duration: stemPlaybackController.duration,
                        currentTime: stemPlaybackController.currentTime,
                        onSeek: { f in stemPlaybackController.seek(to: f * stemPlaybackController.duration) }
                    )
                    .frame(height: 18)
                    .frame(maxWidth: .infinity)
                    Spacer().frame(width: 118)
                    Spacer().frame(width: 136)
                    Color.clear.frame(width: 26, height: 20)
                }
                .padding(.horizontal, 10)
            }
            .padding(.top, 10)
            .padding(.bottom, 6)
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: stemPlaybackController.currentTime) { _, newValue in
                if !isStrataDragging {
                    strataSliderValue = newValue
                }
            }
            .onAppear {
                strataSliderValue = stemPlaybackController.currentTime
            }

            Divider().opacity(0.08)

            // Rows
            VStack(spacing: 0) {
                ForEach(orderedStems, id: \.name) { stem in
                    StratumRowView(
                        artifact: stem,
                        stemPlaybackController: stemPlaybackController,
                        onExport: { artifact, format in
                            export(artifact, as: format)
                        },
                        isMp3ExportReady: inferenceController.isMp3ExportReady,
                        isExporting: isExporting
                    )
                    if stem.name != orderedStems.last?.name {
                        Divider().opacity(0.06).padding(.horizontal, 10)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))

            // Footer: selected-mix export (kept outside per-row flow) — WAV does not require FFmpeg
            HStack(spacing: 10) {
                Button {
                    exportMix(stemPlaybackController.selectedStems, as: .mp3)
                } label: {
                    Label("Export Selected MP3", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                .disabled(stemPlaybackController.selectedStems.count < 2 || !inferenceController.isMp3ExportReady || isExporting)
                .help("Export the stems currently selected by Mute and Solo as one MP3 mix")
                .accessibilityIdentifier("ExportSelectedStemMix")
                Menu {
                    Button("Export Selected WAV") { exportMix(stemPlaybackController.selectedStems, as: .wav) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .disabled(stemPlaybackController.selectedStems.count < 2 || isExporting)
                .help("Export Selected WAV — available without FFmpeg")
                .accessibilityIdentifier("ExportSelectedWAVMenu")
                Spacer()
                Text(effectiveDisplayTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("StrataDisplayTitle")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
            if let exportingFileName {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6).tint(.secondary)
                    Text("Exporting \(exportingFileName)…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityIdentifier("StrataExportStatus")
            } else if let savedFileName {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Saved \(savedFileName)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .accessibilityIdentifier("StrataExportStatus")
            }
            if let r = inferenceController.runtimeReadiness, !r.isMp3ExportReady {
                Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).padding(.horizontal, 12).padding(.bottom, 6)
                    .accessibilityIdentifier("Mp3ExportHint")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.13), lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .alert("Export Failed", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } }
        )) {
            Button("OK") { exportErrorMessage = nil }
        } message: {
            if let exportErrorMessage { Text(exportErrorMessage) }
        }
    }

    // MARK: - Export (mirrors InferenceCard, uses same StemExporter + folder preference)

    private var storagePreferences: StorageLocationPreferences { StorageLocationPreferences() }

    private func export(_ artifact: StemArtifact, as format: StemExportFormat) {
        guard !isExporting else { return }
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let ffmpegURL = inferenceController.runtimeReadiness?.ffmpegExecutableURL
        let capturedQuality = mp3Quality
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultFilename(for: artifact.name, format: format, sourceBaseName: inferenceController.effectiveExportBaseName)
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = storagePreferences.applyExportDefaultDirectory(to: panel)
        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let dest = panel.url else { return }
                exportingFileName = dest.lastPathComponent
                savedFileName = nil
                Task { [defaultDirectoryAccess, capturedQuality, ffmpegURL] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.export(artifact, to: dest, format: format, metadata: metadata, artworkURL: artworkURL, mp3Quality: capturedQuality, ffmpegURL: ffmpegURL)
                        }.value
                        await MainActor.run {
                            exportingFileName = nil
                            savedFileName = dest.lastPathComponent
                        }
                    } catch {
                        await MainActor.run {
                            exportingFileName = nil
                            exportErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    private func exportMix(_ artifacts: [StemArtifact], as format: StemExportFormat = .mp3) {
        guard artifacts.count >= 2 else { return }
        guard !isExporting else { return }
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let ffmpegURL = inferenceController.runtimeReadiness?.ffmpegExecutableURL
        let gains = stemPlaybackController.stemGains
        let capturedQuality = mp3Quality
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultMixFilename(for: artifacts.map(\.name), format: format, sourceBaseName: inferenceController.effectiveExportBaseName)
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = storagePreferences.applyExportDefaultDirectory(to: panel)
        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let dest = panel.url else { return }
                exportingFileName = dest.lastPathComponent
                savedFileName = nil
                Task { [defaultDirectoryAccess, capturedQuality, ffmpegURL] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.exportMix(artifacts, to: dest, gains: gains, format: format, metadata: metadata, artworkURL: artworkURL, mp3Quality: capturedQuality, ffmpegURL: ffmpegURL)
                        }.value
                        await MainActor.run {
                            exportingFileName = nil
                            savedFileName = dest.lastPathComponent
                        }
                    } catch {
                        await MainActor.run {
                            exportingFileName = nil
                            exportErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}
