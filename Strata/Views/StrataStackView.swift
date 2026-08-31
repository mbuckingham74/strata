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
//   Left label column (110pt) and right control columns are fixed,
//   so GeometryReader-derived waveform widths are identical across rows.
//   The shared ruler at the top uses the identical HStack insets, so its
//   ticks line up with waveforms.
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
    case .other: return Color.white.opacity(0.55)
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

    @State private var samples: [Float]? = nil
    @State private var isLoading = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let fraction: CGFloat = duration > 0 ? CGFloat(min(max(currentTime / duration, 0), 1)) : 0
            let playheadX = fraction * w

            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.06), lineWidth: 1))

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
                            // Slight opacity lift for very low amps already handled in provider
                            context.fill(path, with: .color(color.opacity(0.92)))
                        }
                    }
                } else if isLoading {
                    HStack { Spacer(); ProgressView().scaleEffect(0.55).tint(.white.opacity(0.35)); Spacer() }
                } else {
                    // Empty but not loading: thin midline so alignment still reads as a stratum
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).frame(maxHeight: .infinity, alignment: .center)
                }

                // Vertical playhead — 1pt line + dot
                if duration > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.95))
                        .frame(width: 1.2, height: h)
                        .shadow(color: Color.black.opacity(0.45), radius: 2, x: 0, y: 0)
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
                            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 8)
                            Text(StemPlaybackController.formattedTime(t))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Ruler playhead (thin line)
                if duration > 0 {
                    Rectangle().fill(Color.white.opacity(0.55)).frame(width: 1, height: geo.size.height).offset(x: fraction * w)
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

    private var color: Color { strataColor(for: artifact.name) }

    var body: some View {
        HStack(spacing: 10) {
            // Left: stem identity
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.18))
                        .frame(width: 22, height: 22)
                    Image(systemName: strataIcon(for: artifact.name))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(artifact.name.rawValue.capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            .frame(width: 110, alignment: .leading)

            // Center: waveform (flex — identical width across rows ensures timeline alignment)
            WaveformView(
                url: artifact.url,
                color: color,
                duration: stemPlaybackController.duration,
                currentTime: stemPlaybackController.currentTime,
                onSeek: { fraction in
                    let t = fraction * stemPlaybackController.duration
                    stemPlaybackController.seek(to: t)
                }
            )
            .frame(height: 34)
            .frame(maxWidth: .infinity)

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
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 96)

            // Audibility controls (preserve existing mute/solo)
            StemAudibilityControls(stemPlaybackController: stemPlaybackController, stem: artifact.name)
                .frame(width: 112)

            // Export per stem
            Menu {
                Button("WAV") { onExport(artifact, .wav) }
                Button("MP3") { onExport(artifact, .mp3) }
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityIdentifier("ExportStem-\(artifact.name.rawValue)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Stacked strata (shared timeline)

struct StrataStackView: View {
    let result: SeparationResult
    @Bindable var stemPlaybackController: StemPlaybackController
    @Bindable var inferenceController: InferenceController

    @State private var exportErrorMessage: String?

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
            // Card header: subtle strata label + transport hint
            HStack(spacing: 8) {
                Label("Strata — 6 layers", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                // Small time read-out aligned to shared timeline
                Text("\(stemPlaybackController.formattedCurrentTime) / \(stemPlaybackController.formattedDuration)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Shared ruler — same HStack insets as rows so ticks align with waveforms
            HStack(spacing: 10) {
                Spacer().frame(width: 110)
                StrataRulerView(
                    duration: stemPlaybackController.duration,
                    currentTime: stemPlaybackController.currentTime,
                    onSeek: { f in stemPlaybackController.seek(to: f * stemPlaybackController.duration) }
                )
                .frame(height: 20)
                .frame(maxWidth: .infinity)
                // Match right-side fixed columns (gain slider + controls + export)
                Spacer().frame(width: 96)
                Spacer().frame(width: 112)
                Color.clear.frame(width: 26, height: 20)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 2)

            Divider().opacity(0.08)

            // Rows
            VStack(spacing: 0) {
                ForEach(orderedStems, id: \.name) { stem in
                    StratumRowView(
                        artifact: stem,
                        stemPlaybackController: stemPlaybackController,
                        onExport: { artifact, format in
                            export(artifact, as: format)
                        }
                    )
                    if stem.name != orderedStems.last?.name {
                        Divider().opacity(0.06).padding(.horizontal, 10)
                    }
                }
            }
            .background(Color.white.opacity(0.02))

            // Footer: selected-mix export (kept outside per-row flow)
            HStack(spacing: 10) {
                Menu {
                    Button("Export Selected WAV") { exportMix(stemPlaybackController.selectedStems, as: .wav) }
                } label: {
                    Label("Export Selected MP3", systemImage: "square.and.arrow.down.on.square")
                } primaryAction: {
                    exportMix(stemPlaybackController.selectedStems)
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                .disabled(stemPlaybackController.selectedStems.count < 2)
                .help("Export the stems currently selected by Mute and Solo as one MP3 mix, or choose WAV")
                .accessibilityIdentifier("ExportSelectedStemMix")
                Spacer()
                Text(effectiveDisplayTitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("StrataDisplayTitle")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.03))
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
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

    private var exportFolderPreference: ExportFolderPreference { ExportFolderPreference() }

    private func export(_ artifact: StemArtifact, as format: StemExportFormat) {
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultFilename(for: artifact.name, format: format, sourceBaseName: inferenceController.effectiveExportBaseName)
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = exportFolderPreference.applyDefaultDirectory(to: panel)
        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let dest = panel.url else { return }
                Task { [defaultDirectoryAccess] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.export(artifact, to: dest, format: format, metadata: metadata, artworkURL: artworkURL)
                        }.value
                    } catch { exportErrorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func exportMix(_ artifacts: [StemArtifact], as format: StemExportFormat = .mp3) {
        guard artifacts.count >= 2 else { return }
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultMixFilename(for: artifacts.map(\.name), format: format, sourceBaseName: inferenceController.effectiveExportBaseName)
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = exportFolderPreference.applyDefaultDirectory(to: panel)
        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let dest = panel.url else { return }
                Task { [defaultDirectoryAccess] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.exportMix(artifacts, to: dest, format: format, metadata: metadata, artworkURL: artworkURL)
                        }.value
                    } catch { exportErrorMessage = error.localizedDescription }
                }
            }
        }
    }
}
