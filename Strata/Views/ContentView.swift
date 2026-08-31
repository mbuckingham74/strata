import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @Bindable var playbackController: PlaybackController
    @Bindable var inferenceController: InferenceController
    @Bindable var stemPlaybackController: StemPlaybackController

    // Backward compat for preview / tests that use single arg: provide convenience init
    init(
        playbackController: PlaybackController,
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController
    ) {
        self.playbackController = playbackController
        self.inferenceController = inferenceController
        self.stemPlaybackController = stemPlaybackController
    }
    init(playbackController: PlaybackController, inferenceController: InferenceController) {
        self.init(
            playbackController: playbackController,
            inferenceController: inferenceController,
            stemPlaybackController: StemPlaybackController()
        )
    }
    init(controller: PlaybackController) {
        self.init(
            playbackController: controller,
            inferenceController: InferenceController(),
            stemPlaybackController: StemPlaybackController()
        )
    }

    @State private var showingImporter = false
    @State private var showingInferenceImporter = false
    @State private var inferenceInputURL: URL?
    @State private var showingError = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                controller: playbackController,
                stemPlaybackController: stemPlaybackController,
                inferenceController: inferenceController,
                showingImporter: $showingImporter
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            MainWorkspaceView(
                controller: playbackController,
                showingImporter: $showingImporter,
                inferenceController: inferenceController,
                stemPlaybackController: stemPlaybackController,
                inferenceInputURL: $inferenceInputURL,
                showingInferenceImporter: $showingInferenceImporter
            )
            .background(Color(nsColor: .underPageBackgroundColor).opacity(0.0))
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.audio, .mp3, .wav, .aiff, UTType(filenameExtension: "m4a")].compactMap { $0 },
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                playbackController.load(url: url)
            case .failure(let error):
                playbackController.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $showingInferenceImporter,
            allowedContentTypes: [.wav, .audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                // Keep a bookmark-safe copy outside sandbox
                inferenceInputURL = url
            case .failure(let error):
                inferenceController.cancel()
                // Surface via inference error state? Use status
                break
            }
        }
        .alert("Playback Error", isPresented: Binding(
            get: { playbackController.errorMessage != nil },
            set: { if !$0 { playbackController.errorMessage = nil } }
        )) {
            Button("OK") { playbackController.errorMessage = nil }
        } message: {
            if let msg = playbackController.errorMessage { Text(msg) }
        }
        .alert("Inference Error", isPresented: Binding(
            get: { inferenceController.errorMessage != nil && inferenceController.state != .failed("Cancelled") },
            set: { if !$0 { /* keep */ } }
        )) {
            Button("OK") { }
        } message: {
            if let msg = inferenceController.errorMessage { Text(msg) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingImporter = true } label: { Label("Add Audio", systemImage: "plus") }.help("Add Audio")
            }
        }
    }
}

// MARK: - Sidebar (YouTube-aware: reflects PlaybackController OR StemPlaybackController)

struct SidebarView: View {
    @Bindable var controller: PlaybackController
    @Bindable var stemPlaybackController: StemPlaybackController
    @Bindable var inferenceController: InferenceController
    @Binding var showingImporter: Bool

    // Primary initializer (YouTube-aware)
    init(
        controller: PlaybackController,
        stemPlaybackController: StemPlaybackController,
        inferenceController: InferenceController,
        showingImporter: Binding<Bool>
    ) {
        self.controller = controller
        self.stemPlaybackController = stemPlaybackController
        self.inferenceController = inferenceController
        self._showingImporter = showingImporter
    }

    var effectiveHasFile: Bool {
        controller.hasFile || stemPlaybackController.hasStems
    }

    var effectiveTitle: String? {
        if controller.hasFile, let t = controller.title { return t }
        if stemPlaybackController.hasStems {
            if let t = stemPlaybackController.title, !t.isEmpty { return t }
            if let base = inferenceController.exportBaseName, !base.isEmpty { return base }
            let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !editable.isEmpty { return editable }
        }
        return nil
    }

    var effectiveDuration: String {
        if controller.hasFile { return controller.formattedDuration }
        if stemPlaybackController.hasStems { return stemPlaybackController.formattedDuration }
        return controller.formattedDuration
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Library", systemImage: "music.note.list")
                    .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button { showingImporter = true } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help("Add Audio").accessibilityLabel("Add Audio")
            }.padding(.horizontal, 14).padding(.vertical, 12)
            Divider().opacity(0.15)
            if effectiveHasFile, let title = effectiveTitle {
                ScrollView { VStack(spacing: 6) { SidebarEntry(title: title, duration: effectiveDuration, isSelected: true).padding(.horizontal, 8).padding(.top, 8) } }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "music.note").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                    Text("No audio loaded").font(.callout).foregroundStyle(.secondary)
                    Text("Add a local audio file to begin.").font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).padding(.horizontal, 20)
                    Button { showingImporter = true } label: { Text("Add Audio").font(.callout.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 6) }.buttonStyle(.borderedProminent).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).accessibilityLabel("Add Audio")
                    Spacer()
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(Color.green.opacity(0.9)).frame(width: 6, height: 6)
                Text("Engine ready · 100% local").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 10).background(.white.opacity(0.03)).overlay(Divider().opacity(0.1), alignment: .top)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SidebarEntry: View {
    let title: String
    let duration: String
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.22)).frame(width: 36, height: 36)
                Image(systemName: "waveform").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1).foregroundStyle(.primary)
                Text(duration).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(.horizontal, 10).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.white.opacity(0.08) : Color.clear)).overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.white.opacity(0.08) : Color.clear, lineWidth: 1))
    }
}

// MARK: - Main Workspace

struct MainWorkspaceView: View {
    @Bindable var controller: PlaybackController
    @Binding var showingImporter: Bool
    @Bindable var inferenceController: InferenceController
    @Bindable var stemPlaybackController: StemPlaybackController
    @Binding var inferenceInputURL: URL?
    @Binding var showingInferenceImporter: Bool

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.11).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Selected-audio header
                    if controller.hasFile {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(controller.title ?? "Untitled").font(.title3.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(controller.formattedDuration).font(.caption).foregroundStyle(.secondary)
                                Text("·").foregroundStyle(.tertiary)
                                Text("Original mix").font(.caption).foregroundStyle(.secondary)
                                Text("·").foregroundStyle(.tertiary)
                                Text("Local file").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal, 24).padding(.top, 24)
                        TransportCard(controller: controller).padding(.horizontal, 24)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Tracks").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 24).padding(.bottom, 8)
                            OriginalMixRow(controller: controller).padding(.horizontal, 24)
                        }
                    } else {
                        EmptyStateView(showingImporter: $showingImporter).frame(height: 260).padding(.top, 20)
                    }

                    // M3 Inference Bridge (minimal proof UI)
                    InferenceCard(
                        inferenceController: inferenceController,
                        stemPlaybackController: stemPlaybackController,
                        inferenceInputURL: $inferenceInputURL,
                        showingInferenceImporter: $showingInferenceImporter
                    ).padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }
    }
}

// Fallback for old call site
extension MainWorkspaceView {
    init(controller: PlaybackController, showingImporter: Binding<Bool>) {
        self.controller = controller
        self._showingImporter = showingImporter
        self.inferenceController = InferenceController()
        self.stemPlaybackController = StemPlaybackController()
        self._inferenceInputURL = .constant(nil)
        self._showingInferenceImporter = .constant(false)
    }
}

struct EmptyStateView: View {
    @Binding var showingImporter: Bool
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)).frame(width: 72, height: 72)
                Image(systemName: "music.note").font(.system(size: 30, weight: .light)).foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95))
            }
            VStack(spacing: 8) {
                Text("No audio selected").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text("Add a local audio file to play, pause, and seek through AVAudioEngine.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            }
            Button { showingImporter = true } label: { Label("Add Audio", systemImage: "plus").font(.callout.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).accessibilityLabel("Add Audio")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Inference Card (M3 minimal)

struct InferenceCard: View {
    @Bindable var inferenceController: InferenceController
    @Bindable var stemPlaybackController: StemPlaybackController
    @Binding var inferenceInputURL: URL?
    @Binding var showingInferenceImporter: Bool
    private let exportFolderPreference = ExportFolderPreference()
    @State private var youTubeURLString = ""
    @State private var exportErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Separation", systemImage: "waveform.path.badge.magnifyingglass").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                Spacer()
                Button {
                    chooseDefaultExportFolder()
                } label: {
                    Label("Export Folder…", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Choose the default folder shown by export save panels")
                .accessibilityIdentifier("ChooseDefaultExportFolder")
                if inferenceController.isSeparating {
                    ProgressView().scaleEffect(0.7).tint(.white)
                }
            }
            Text("Local BS-RoFormer via MLX — proves Swift ownership of the inference worker.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            // Input picker
            HStack(spacing: 10) {
                Button { showingInferenceImporter = true } label: {
                    Label(inferenceInputURL == nil ? "Choose WAV" : "Change WAV", systemImage: "doc.badge.ellipsis").font(.callout.weight(.medium))
                }.buttonStyle(.bordered).tint(.white).disabled(inferenceController.isSeparating)
                if let url = inferenceInputURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                } else {
                    Text("No file chosen").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                }
            }

            // YouTube URL (M4 minimal)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Paste YouTube URL", text: $youTubeURLString)
                    .textFieldStyle(.roundedBorder)
                    .disabled(inferenceController.isSeparating)
                    .accessibilityLabel("YouTube URL")
                    .accessibilityIdentifier("YouTubeURLField")
                HStack(spacing: 10) {
                    Button {
                        let trimmed = youTubeURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
                        inferenceController.startSeparation(youTubeURL: url)
                    } label: {
                        Label("Separate from YouTube", systemImage: "link").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                    .disabled(youTubeURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inferenceController.isSeparating)
                    .accessibilityIdentifier("SeparateFromYouTubeButton")

                    Button {
                        let trimmed = youTubeURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
                        inferenceController.prepareYouTubeMP3Export(youTubeURL: url)
                    } label: {
                        Label("Save MP3", systemImage: "square.and.arrow.down").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(youTubeURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inferenceController.isSeparating)
                    .accessibilityIdentifier("SaveYouTubeMP3Button")
                }
            }

            // Start / Cancel
            HStack(spacing: 10) {
                Button {
                    guard let url = inferenceInputURL else { return }
                    inferenceController.startSeparation(inputURL: url)
                } label: {
                    Label("Separate", systemImage: "play.fill").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).disabled(inferenceInputURL == nil || inferenceController.isSeparating)

                if inferenceController.isSeparating {
                    Button(role: .destructive) { inferenceController.cancel() } label: { Text("Cancel").font(.callout.weight(.medium)) }.buttonStyle(.bordered).tint(.red)
                }
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(statusColor)
            }

            // Failure
            if case .failed(let msg) = inferenceController.state, msg != "Cancelled" {
                Text(msg).font(.caption).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true).padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if inferenceController.isEditableMetadataAvailable {
                EditableMetadataEditor(inferenceController: inferenceController)
            }

            // Completed stems
            if case .completed = inferenceController.state, let result = inferenceController.result {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stems — 6 validated").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    HStack(spacing: 10) {
                        Button {
                            if stemPlaybackController.isPlaying {
                                stemPlaybackController.pause()
                            } else {
                                stemPlaybackController.play()
                            }
                        } label: {
                            Label(
                                stemPlaybackController.isPlaying ? "Pause" : "Play",
                                systemImage: stemPlaybackController.isPlaying ? "pause.fill" : "play.fill"
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(!stemPlaybackController.hasStems)

                        Slider(
                            value: Binding(
                                get: { stemPlaybackController.currentTime },
                                set: { stemPlaybackController.seek(to: $0) }
                            ),
                            in: 0...(stemPlaybackController.duration > 0 ? stemPlaybackController.duration : 1)
                        )
                        .disabled(!stemPlaybackController.hasStems)
                        .accessibilityLabel("Seek stems")

                        Text("\(stemPlaybackController.formattedCurrentTime) / \(stemPlaybackController.formattedDuration)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let errorMessage = stemPlaybackController.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red.opacity(0.9))
                    }
                    // M7: six visually stacked strata sharing one horizontal timeline.
                    // Fixed display order (Vocals▶Other), real waveforms via WaveformProvider,
                    // shared ruler + per-waveform playhead driven by stemPlaybackController.
                    StrataStackView(
                        result: result,
                        stemPlaybackController: stemPlaybackController,
                        inferenceController: inferenceController
                    )
                }.padding(.top, 4)
            }
        }.padding(16).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1)))
            .onChange(of: inferenceController.result) { _, result in
                guard let result else { return }
                loadCompletedResult(result)
            }
            .onChange(of: inferenceController.preparedYouTubeMP3Export) { _, preparation in
                guard let preparation else { return }
                exportYouTubeMP3(preparation)
            }
            .alert("Export Failed", isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )) {
                Button("OK") { exportErrorMessage = nil }
            } message: {
                if let exportErrorMessage { Text(exportErrorMessage) }
            }
    }

    func loadCompletedResult(_ result: SeparationResult) {
        // Prefer already-available ingest metadata ("Snow Patrol - Run") over raw inputURL ("mixture")
        let displayName: String? = {
            if let base = inferenceController.exportBaseName, !base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return base
            }
            let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !editable.isEmpty { return editable }
            return nil
        }()
        if let displayName {
            stemPlaybackController.load(result: result, displayName: displayName)
        } else {
            stemPlaybackController.load(result: result)
        }
    }

    private func chooseDefaultExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Choose the default folder for future exports."
        let defaultDirectoryAccess = exportFolderPreference.resolvedDefaultDirectory()
        panel.directoryURL = defaultDirectoryAccess?.url

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let directoryURL = panel.url else { return }
                do {
                    try exportFolderPreference.setDefaultDirectory(directoryURL)
                } catch {
                    exportErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func export(_ artifact: StemArtifact, as format: StemExportFormat) {
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultFilename(
            for: artifact.name,
            format: format,
            sourceBaseName: inferenceController.exportBaseName
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = exportFolderPreference.applyDefaultDirectory(to: panel)

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
                Task { [defaultDirectoryAccess] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.export(
                                artifact,
                                to: destinationURL,
                                format: format,
                                metadata: metadata,
                                artworkURL: artworkURL
                            )
                        }.value
                    } catch {
                        exportErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func exportMix(
        _ artifacts: [StemArtifact],
        as format: StemExportFormat = .mp3
    ) {
        guard artifacts.count >= 2 else { return }
        let metadata = format == .mp3 ? inferenceController.effectiveYouTubeMetadata : nil
        let artworkURL = format == .mp3 ? inferenceController.effectiveArtworkURL : nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultMixFilename(
            for: artifacts.map(\.name),
            format: format,
            sourceBaseName: inferenceController.exportBaseName
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = exportFolderPreference.applyDefaultDirectory(to: panel)

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
                Task { [defaultDirectoryAccess] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.exportMix(
                                artifacts,
                                to: destinationURL,
                                format: format,
                                metadata: metadata,
                                artworkURL: artworkURL
                            )
                        }.value
                    } catch {
                        exportErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func exportYouTubeMP3(_ preparation: YouTubeIngestResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mp3]
        panel.nameFieldStringValue = StemExporter.defaultYouTubeMP3Filename(
            metadata: preparation.metadata
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = exportFolderPreference.applyDefaultDirectory(to: panel)

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
                let effectiveMetadata = self.inferenceController.effectiveYouTubeMetadata
                let effectiveArtwork = self.inferenceController.effectiveArtworkURL
                Task { [defaultDirectoryAccess] in
                    defer { withExtendedLifetime(defaultDirectoryAccess) {} }
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try StemExporter.exportMP3(
                                from: preparation.audioURL,
                                to: destinationURL,
                                metadata: effectiveMetadata,
                                artworkURL: effectiveArtwork
                            )
                        }.value
                    } catch {
                        exportErrorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private var statusText: String {
        switch inferenceController.state {
        case .idle: return "Ready"
        case .loadingModel: return inferenceController.statusMessage
        case .separating: return "Separating…"
        case .completed: return "Complete"
        case .failed(let m): return m
        }
    }
    private var statusColor: Color {
        switch inferenceController.state {
        case .idle: return .secondary
        case .loadingModel, .separating: return Color(red: 0.56, green: 0.46, blue: 0.95)
        case .completed: return .green
        case .failed(let m) where m == "Cancelled": return .secondary
        case .failed: return .red
        }
    }
    private func icon(for stem: StemName) -> String {
        switch stem {
        case .vocals: return "mic.fill"
        case .drums: return "drum.fill"
        case .bass: return "guitars.fill"
        case .guitar: return "guitars"
        case .piano: return "pianokeys"
        case .other: return "music.note"
        }
    }
}

struct EditableMetadataEditor: View {
    @Bindable var inferenceController: InferenceController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MP3 Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text("Edit ID3 metadata written into MP3 exports.").font(.caption2).foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Title").font(.caption2).foregroundStyle(.secondary)
                        TextField("Title", text: $inferenceController.editableTitle)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ID3TitleField")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Artist").font(.caption2).foregroundStyle(.secondary)
                        TextField("Artist", text: $inferenceController.editableArtist)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ID3ArtistField")
                    }
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Album").font(.caption2).foregroundStyle(.secondary)
                        TextField("Album", text: $inferenceController.editableAlbum)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ID3AlbumField")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Album Artist").font(.caption2).foregroundStyle(.secondary)
                        TextField("Album Artist", text: $inferenceController.editableAlbumArtist)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ID3AlbumArtistField")
                    }
                }
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Year").font(.caption2).foregroundStyle(.secondary)
                        TextField("Year", text: $inferenceController.editableYear)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ID3YearField")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Genre").font(.caption2).foregroundStyle(.secondary)
                        TextField("Genre", text: $inferenceController.editableGenre)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ID3GenreField")
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Track #").font(.caption2).foregroundStyle(.secondary)
                        TextField("Track #", text: $inferenceController.editableTrackNumber)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("ID3TrackNumberField")
                    }
                }
            }
            Divider().opacity(0.12)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Artwork").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(artworkStatusText).font(.caption2).foregroundStyle(.tertiary)
                }
                if let previewURL = inferenceController.effectiveArtworkURL {
                    HStack(spacing: 10) {
                        if let nsImage = NSImage(contentsOf: previewURL) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12), lineWidth: 1))
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)).frame(width: 56, height: 56).overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                        }
                        Text(previewURL.lastPathComponent).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                } else {
                    Text("No artwork — MP3 will have no cover image").font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 8) {
                    Button("Keep") { inferenceController.editableArtwork = .keep }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("ID3ArtworkKeep")
                        .disabled(!canKeep)
                    Button("Remove") { inferenceController.editableArtwork = .removed }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("ID3ArtworkRemove")
                    Button("Replace…") { chooseReplacementArtwork() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("ID3ArtworkReplace")
                }
            }
        }.padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1)))
    }

    private var artworkStatusText: String {
        switch inferenceController.editableArtwork {
        case .keep: return inferenceController.effectiveArtworkURL != nil ? "Keep" : "Keep (none)"
        case .removed: return "Removed"
        case .replaced: return "Replaced"
        }
    }

    private var canKeep: Bool {
        if case .keep = inferenceController.editableArtwork { return false }
        return true
    }

    private func chooseReplacementArtwork() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            inferenceController.editableArtwork = .replaced(url)
        }
    }
}

struct StemAudibilityControls: View {
    @Bindable var stemPlaybackController: StemPlaybackController
    let stem: StemName

    var isMuted: Bool {
        stemPlaybackController.mutedStems.contains(stem)
    }

    var isSoloed: Bool {
        stemPlaybackController.soloedStems.contains(stem)
    }

    var muteBinding: Binding<Bool> {
        Binding(
            get: { isMuted },
            set: { stemPlaybackController.setMuted($0, for: stem) }
        )
    }

    var soloBinding: Binding<Bool> {
        Binding(
            get: { isSoloed },
            set: { stemPlaybackController.setSoloed($0, for: stem) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Mute", isOn: muteBinding)
                .toggleStyle(.button)
                .tint(.red)
                .accessibilityIdentifier("StemMute-\(stem.rawValue)")
            Toggle("Solo", isOn: soloBinding)
                .toggleStyle(.button)
                .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                .accessibilityIdentifier("StemSolo-\(stem.rawValue)")
        }
        .controlSize(.small)
        .disabled(!stemPlaybackController.hasStems)
    }
}

// MARK: - Transport Card

struct TransportCard: View {
    @Bindable var controller: PlaybackController
    @State private var sliderValue: Double = 0
    @State private var isDragging = false
    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                HStack {
                    Text(controller.formattedTime(isDragging ? sliderValue : controller.currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                    Slider(value: Binding(get: { isDragging ? sliderValue : controller.currentTime }, set: { newVal in sliderValue = newVal }), in: 0...(controller.duration > 0 ? controller.duration : 1), onEditingChanged: { editing in isDragging = editing; if editing { sliderValue = controller.currentTime } else { controller.seek(to: sliderValue) } }).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).disabled(!controller.hasFile).accessibilityLabel("Seek")
                    Text(controller.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            HStack {
                Button { if controller.isPlaying { controller.pause() } else { controller.play() } } label: { Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).frame(width: 36, height: 36).background(Color(red: 0.56, green: 0.46, blue: 0.95), in: Circle()).shadow(color: Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.4), radius: 8, y: 2) }.buttonStyle(.plain).disabled(!controller.hasFile).accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(controller.isPlaying ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(controller.isPlaying ? "Playing" : "Paused").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(16).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))).onChange(of: controller.currentTime) { _, newValue in if !isDragging { sliderValue = newValue } }.onAppear { sliderValue = controller.currentTime }
    }
}

// MARK: - Original Mix Row

struct OriginalMixRow: View {
    @Bindable var controller: PlaybackController
    var body: some View {
        HStack(spacing: 12) {
            ZStack { RoundedRectangle(cornerRadius: 8).fill(Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.18)).frame(width: 32, height: 32); Image(systemName: "waveform.path.ecg").font(.system(size: 14, weight: .medium)).foregroundStyle(Color(red: 0.56, green: 0.46, blue: 0.95)) }
            Text("Original mix").font(.callout.weight(.medium)).foregroundStyle(.white)
            Spacer()
            Text(controller.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.vertical, 12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1)))
    }
}

#Preview {
    let fake = FakePreviewTransport()
    let ctrl = PlaybackController(transport: fake)
    let ic = InferenceController()
    let sc = StemPlaybackController()
    ContentView(playbackController: ctrl, inferenceController: ic, stemPlaybackController: sc).frame(width: 900, height: 600)
}

@MainActor
private final class FakePreviewTransport: AudioTransport {
    var duration: TimeInterval = 187
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 42
    var onCompletion: (() -> Void)?
    func load(url: URL) throws {}
    func play() { isPlaying = true }
    func pause() { isPlaying = false }
    func seek(to time: TimeInterval) { currentTime = time }
    func stop() { isPlaying = false }
}
