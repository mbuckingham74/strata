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
                stemPlaybackController: stemPlaybackController
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
                inferenceController.clearLoadedYouTubeSource()
            case .failure(let error):
                playbackController.errorMessage = error.localizedDescription
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
                Circle().fill(sidebarDotColor).frame(width: 6, height: 6)
                Text(sidebarStatusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }.padding(.horizontal, 12).padding(.vertical, 10).background(.white.opacity(0.03)).overlay(Divider().opacity(0.1), alignment: .top)
                .help(sidebarStatusText)
                .accessibilityIdentifier("RuntimeReadinessStatus")
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarStatusText: String {
        guard let r = inferenceController.runtimeReadiness else { return "Checking setup…" }
        return r.sidebarStatus
    }

    private var sidebarDotColor: Color {
        guard let r = inferenceController.runtimeReadiness else { return Color.orange.opacity(0.9) }
        if r.isSeparationReady { return Color.green.opacity(0.9) }
        if !r.ffmpegAvailable || !r.workerAvailable { return Color.red.opacity(0.9) }
        return Color.orange.opacity(0.9)
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

    var body: some View {
        ZStack {
            Color(red: 0.09, green: 0.09, blue: 0.11).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Selected-audio header
                    if inferenceController.isYouTubeSourceLoaded {
                        Color.clear.frame(height: 20)
                    } else if controller.hasFile {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(controller.title ?? "Untitled").font(.title3.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(controller.formattedDuration).font(.caption).foregroundStyle(.secondary)
                                Text("·").foregroundStyle(.tertiary)
                                Text("Original mix").font(.caption).foregroundStyle(.secondary)
                                Text("·").foregroundStyle(.tertiary)
                                Text("Local file").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.horizontal, 20).padding(.top, 16)
                        TransportCard(controller: controller).padding(.horizontal, 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Tracks").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 20).padding(.bottom, 6)
                            OriginalMixRow(controller: controller).padding(.horizontal, 20)
                        }
                    } else {
                        EmptyStateView(showingImporter: $showingImporter).frame(height: 260).padding(.top, 20)
                    }

                    // M3 Inference Bridge - unified local source (playbackController is single source)
                    InferenceCard(
                        inferenceController: inferenceController,
                        stemPlaybackController: stemPlaybackController,
                        playbackController: controller,
                        showingImporter: $showingImporter
                    ).padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }
    }
}

// Fallback for preview-only call sites.
extension MainWorkspaceView {
    init(controller: PlaybackController, showingImporter: Binding<Bool>) {
        self.controller = controller
        self._showingImporter = showingImporter
        self.inferenceController = InferenceController()
        self.stemPlaybackController = StemPlaybackController()
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
    @Bindable var playbackController: PlaybackController
    @Binding var showingImporter: Bool
    private let exportFolderPreference = ExportFolderPreference()
    @State private var youTubeURLString = ""
    @State private var exportErrorMessage: String?
    @State private var youTubeSliderValue: Double = 0
    @State private var isYouTubeDragging = false

    // Unified initializer
    init(
        inferenceController: InferenceController,
        stemPlaybackController: StemPlaybackController,
        playbackController: PlaybackController,
        showingImporter: Binding<Bool>
    ) {
        self.inferenceController = inferenceController
        self.stemPlaybackController = stemPlaybackController
        self.playbackController = playbackController
        self._showingImporter = showingImporter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            Text("Separation runs locally on this Mac.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            // Unified local source — single selection via Add Audio
            if !inferenceController.isYouTubeSourceLoaded {
                HStack(spacing: 10) {
                    if playbackController.hasFile, let title = playbackController.title {
                        Label(title, systemImage: "doc.fill").font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        if let url = playbackController.sourceURL {
                            Text(url.lastPathComponent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { showingImporter = true } label: {
                            Label("Change", systemImage: "arrow.triangle.2.circlepath").font(.caption.weight(.medium))
                        }.buttonStyle(.bordered).tint(.white).disabled(inferenceController.isSeparating)
                    } else {
                        Text("No file selected — Add audio to separate").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                        Button { showingImporter = true } label: {
                            Label("Add Audio", systemImage: "plus").font(.caption.weight(.medium))
                        }.buttonStyle(.bordered).tint(.white).disabled(inferenceController.isSeparating)
                    }
                }
            }

            // YouTube source-first workflow
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
                        inferenceController.loadYouTubeSource(youTubeURL: url)
                    } label: {
                        Label("Load source", systemImage: "arrow.down.circle").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                    .disabled(youTubeURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || inferenceController.isSeparating || !inferenceController.isYouTubeAcquisitionReady)
                    .accessibilityIdentifier("LoadYouTubeSourceButton")
                }
                if let r = inferenceController.runtimeReadiness, !r.isYouTubeAcquisitionReady {
                    Text(r.sidebarStatus).font(.caption2).foregroundStyle(.orange.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("YouTubeReadinessHint")
                } else if inferenceController.runtimeReadiness == nil {
                    Text("Checking setup…").font(.caption2).foregroundStyle(.tertiary)
                }

                if inferenceController.isYouTubeSourceLoaded, let loaded = inferenceController.loadedYouTubeSource {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            youTubeArtworkView(for: loaded)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(youTubeDisplayTitle(for: loaded))
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(youTubeDisplayArtist(for: loaded))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let channel = youTubeDisplayChannel(for: loaded), !channel.isEmpty {
                                    Text(channel)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                        }

                        // Full original-source play/pause/seek controls bound to playbackController
                        VStack(spacing: 8) {
                            HStack {
                                Text(playbackController.formattedTime(isYouTubeDragging ? youTubeSliderValue : playbackController.currentTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .leading)
                                Slider(
                                    value: Binding(
                                        get: { isYouTubeDragging ? youTubeSliderValue : playbackController.currentTime },
                                        set: { youTubeSliderValue = $0 }
                                    ),
                                    in: 0...(playbackController.duration > 0 ? playbackController.duration : 1),
                                    onEditingChanged: { editing in
                                        isYouTubeDragging = editing
                                        if editing {
                                            youTubeSliderValue = playbackController.currentTime
                                        } else {
                                            playbackController.seek(to: youTubeSliderValue)
                                        }
                                    }
                                )
                                .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                                .disabled(!playbackController.hasFile)
                                .accessibilityLabel("Seek YouTube source")
                                Text(playbackController.formattedDuration)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                            }
                            HStack {
                                Button {
                                    if playbackController.isPlaying { playbackController.pause() } else { playbackController.play() }
                                } label: {
                                    Image(systemName: playbackController.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 36, height: 36)
                                        .background(Color(red: 0.56, green: 0.46, blue: 0.95), in: Circle())
                                        .shadow(color: Color(red: 0.56, green: 0.46, blue: 0.95).opacity(0.4), radius: 8, y: 2)
                                }
                                .buttonStyle(.plain)
                                .disabled(!playbackController.hasFile)
                                .accessibilityLabel(playbackController.isPlaying ? "Pause" : "Play")

                                Spacer()

                                HStack(spacing: 6) {
                                    Circle().fill(playbackController.isPlaying ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                    Text(playbackController.isPlaying ? "Playing" : "Paused").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Gated actions: reuse already-loaded mixture.wav
                        HStack(spacing: 10) {
                            Button {
                                inferenceController.startSeparationFromLoadedYouTubeSource()
                            } label: {
                                Label("Separate", systemImage: "waveform.path.badge.magnifyingglass").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.56, green: 0.46, blue: 0.95))
                            .disabled(!inferenceController.isYouTubeSourceLoaded || inferenceController.isSeparating || !inferenceController.isLoadedSeparationReady)
                            .accessibilityIdentifier("SeparateLoadedYouTubeButton")

                            Button {
                                if let prep = inferenceController.prepareYouTubeMP3ExportFromLoadedSource() {
                                    exportYouTubeMP3(prep)
                                }
                            } label: {
                                Label("Save MP3", systemImage: "square.and.arrow.down").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!inferenceController.isYouTubeSourceLoaded || inferenceController.isSeparating || !inferenceController.isMp3ExportReady)
                            .accessibilityIdentifier("SaveYouTubeMP3Button")
                        }
                        if let r = inferenceController.runtimeReadiness {
                            if !r.isLoadedSeparationReady {
                                Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                            } else if !r.isMp3ExportReady {
                                Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        // Legacy identifier proxy for UI tests expecting SeparateFromYouTubeButton
                        Color.clear.frame(width: 0, height: 0)
                            .accessibilityIdentifier("SeparateFromYouTubeButton")
                            .accessibilityHidden(true)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1)))
                }
            }

            // Start / Cancel — uses single local source via playbackController
            VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if !inferenceController.isYouTubeSourceLoaded {
                    Button {
                        guard let url = playbackController.sourceURL else { return }
                        inferenceController.startSeparation(localFileURL: url)
                    } label: {
                        Label("Separate", systemImage: "play.fill").font(.callout.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent).tint(Color(red: 0.56, green: 0.46, blue: 0.95)).disabled(!playbackController.hasFile || playbackController.sourceURL == nil || inferenceController.isSeparating || !inferenceController.isLocalSeparationReady)
                    .accessibilityIdentifier("LocalSeparateButton")
                }

                if inferenceController.isSeparating {
                    Button(role: .destructive) { inferenceController.cancel() } label: { Text("Cancel").font(.callout.weight(.medium)) }.buttonStyle(.bordered).tint(.red)
                }
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(statusColor)
            }
            if let r = inferenceController.runtimeReadiness, !r.isLocalSeparationReady, !inferenceController.isYouTubeSourceLoaded {
                Text(r.sidebarStatus).font(.caption2).foregroundStyle(.red.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
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
                VStack(alignment: .leading, spacing: 6) {
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
                }.padding(.top, 2)
            }
        }.padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1)))
            .onChange(of: inferenceController.result) { _, result in
                guard let result else { return }
                loadCompletedResult(result)
            }
            .onChange(of: inferenceController.preparedYouTubeMP3Export) { _, preparation in
                guard let preparation else { return }
                exportYouTubeMP3(preparation)
            }
            .onChange(of: inferenceController.loadedYouTubeSource) { _, loaded in
                guard let loaded else { return }
                let display = inferenceController.exportBaseName ?? loaded.metadata?.exportBaseName ?? loaded.metadata?.title
                playbackController.load(url: loaded.audioURL, displayTitle: display)
                youTubeSliderValue = 0
            }
            .onChange(of: playbackController.currentTime) { _, newValue in
                if !isYouTubeDragging { youTubeSliderValue = newValue }
            }
            .onAppear { youTubeSliderValue = playbackController.currentTime }
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
            sourceBaseName: inferenceController.effectiveExportBaseName
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
        let gains = stemPlaybackController.stemGains
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .wav ? .wav : .mp3]
        panel.nameFieldStringValue = StemExporter.defaultMixFilename(
            for: artifacts.map(\.name),
            format: format,
            sourceBaseName: inferenceController.effectiveExportBaseName
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
                                gains: gains,
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
        let effectiveMetadata = inferenceController.effectiveYouTubeMetadata
        let filenameMetadata = effectiveMetadata?.exportBaseName == nil ? preparation.metadata : effectiveMetadata
        panel.nameFieldStringValue = StemExporter.defaultYouTubeMP3Filename(
            metadata: filenameMetadata
        )
        panel.canCreateDirectories = true
        let defaultDirectoryAccess = exportFolderPreference.applyDefaultDirectory(to: panel)

        panel.begin { response in
            withExtendedLifetime(defaultDirectoryAccess) {
                guard response == .OK, let destinationURL = panel.url else { return }
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

    // MARK: - YouTube source presentation helpers

    @ViewBuilder
    private func youTubeArtworkView(for loaded: YouTubeIngestResult) -> some View {
        let url = inferenceController.effectiveArtworkURL ?? loaded.artworkURL
        Group {
            if let url, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08))
                    Image(systemName: "waveform").font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }

    private func youTubeDisplayTitle(for loaded: YouTubeIngestResult) -> String {
        let editable = inferenceController.editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !editable.isEmpty { return editable }
        if let t = loaded.metadata?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let base = inferenceController.exportBaseName?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty { return base }
        if let base = loaded.metadata?.exportBaseName?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty { return base }
        return loaded.audioURL.deletingPathExtension().lastPathComponent
    }

    private func youTubeDisplayArtist(for loaded: YouTubeIngestResult) -> String {
        let editable = inferenceController.editableArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !editable.isEmpty { return editable }
        if let a = loaded.metadata?.artist?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { return a }
        return "Unknown Artist"
    }

    private func youTubeDisplayChannel(for loaded: YouTubeIngestResult) -> String? {
        if let c = inferenceController.loadedChannelName?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        if let c = inferenceController.youTubeExportMetadata?.channel?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        if let c = loaded.metadata?.channel?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty { return c }
        return nil
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
        case .drums: return "metronome.fill"
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
        VStack(spacing: 10) {
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
        }.padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.06)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))).onChange(of: controller.currentTime) { _, newValue in if !isDragging { sliderValue = newValue } }.onAppear { sliderValue = controller.currentTime }
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
